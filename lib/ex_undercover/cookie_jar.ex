defmodule ExUndercover.CookieJar do
  @moduledoc """
  Shared cookie jar partitioned by WireGuard egress identity.

  Buckets are derived from request metadata and keep cookies isolated per
  egress IP while still allowing normal domain/path matching inside the bucket.
  """

  use GenServer

  alias ExUndercover.Request

  defmodule Cookie do
    @enforce_keys [:name, :value, :domain, :path]
    @type t :: %__MODULE__{
            name: binary(),
            value: binary(),
            domain: binary(),
            path: binary(),
            host_only: boolean(),
            secure: boolean(),
            http_only: boolean(),
            same_site: binary() | nil,
            expires_at: DateTime.t() | nil
          }

    defstruct name: nil,
              value: nil,
              domain: nil,
              path: "/",
              host_only: true,
              secure: false,
              http_only: false,
              same_site: nil,
              expires_at: nil
  end

  @type bucket :: binary()
  @type state :: %{
          optional(bucket()) => %{optional({binary(), binary(), binary()}) => Cookie.t()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec bucket_for(Request.t()) :: bucket()
  def bucket_for(%Request{} = request) do
    metadata = request.metadata

    fetch_metadata(metadata, [
      "cookie_jar_bucket",
      :cookie_jar_bucket,
      "wireguard_ip_address",
      :wireguard_ip_address,
      "wireguard_ip",
      :wireguard_ip,
      "egress_ip_address",
      :egress_ip_address,
      "egress_ip",
      :egress_ip
    ]) || request.proxy_tunnel || "default"
  end

  @spec cookie_header(pid() | atom(), Request.t()) :: binary() | nil
  def cookie_header(server \\ __MODULE__, %Request{} = request) do
    GenServer.call(server, {:cookie_header, request})
  end

  @spec seed_request_cookies(pid() | atom(), Request.t()) :: :ok
  def seed_request_cookies(server \\ __MODULE__, %Request{} = request) do
    case request_cookie_header(request.headers) do
      nil -> :ok
      header -> GenServer.call(server, {:seed_cookie_header, request, header})
    end
  end

  @spec store_response(pid() | atom(), Request.t(), [{binary(), binary()}]) :: :ok
  def store_response(server \\ __MODULE__, %Request{} = request, headers) when is_list(headers) do
    GenServer.call(server, {:store_response, request, headers})
  end

  @spec store_cookies(pid() | atom(), Request.t(), list()) :: :ok
  def store_cookies(server \\ __MODULE__, %Request{} = request, cookies) when is_list(cookies) do
    GenServer.call(server, {:store_cookies, request, cookies})
  end

  @spec clear(pid() | atom(), keyword()) :: :ok
  def clear(server \\ __MODULE__, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:clear, opts})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:cookie_header, request}, _from, state) do
    state = cleanup_expired(state)
    {:reply, build_cookie_header(state, request), state}
  end

  def handle_call({:seed_cookie_header, request, header}, _from, state) do
    {:reply, :ok, put_many(state, request, parse_cookie_header(header, request))}
  end

  def handle_call({:store_response, request, headers}, _from, state) do
    cookies =
      headers
      |> Enum.filter(fn {name, _value} -> String.downcase(name) == "set-cookie" end)
      |> Enum.map(fn {_name, value} -> parse_set_cookie(value, request) end)
      |> Enum.reject(&is_nil/1)

    {:reply, :ok, put_many(state, request, cookies)}
  end

  def handle_call({:store_cookies, request, cookies}, _from, state) do
    cookies =
      cookies
      |> Enum.map(&normalize_cookie_input(&1, request))
      |> Enum.reject(&is_nil/1)

    {:reply, :ok, put_many(state, request, cookies)}
  end

  def handle_call({:clear, opts}, _from, state) do
    {:reply, :ok, clear_state(state, opts)}
  end

  defp build_cookie_header(state, %Request{} = request) do
    uri = URI.parse(request.url)
    bucket = bucket_for(request)
    host = normalize_host(uri.host)
    path = request_path(uri)
    secure? = uri.scheme == "https"

    cookies =
      state
      |> Map.get(bucket, %{})
      |> Map.values()
      |> Enum.filter(&cookie_matches?(&1, host, path, secure?))
      |> Enum.sort_by(fn cookie -> {-String.length(cookie.path), cookie.name} end)
      |> Enum.map_join("; ", fn cookie -> "#{cookie.name}=#{cookie.value}" end)

    case cookies do
      "" -> nil
      value -> value
    end
  end

  defp put_many(state, request, cookies) do
    state = cleanup_expired(state)
    bucket = bucket_for(request)

    bucket_state =
      Enum.reduce(cookies, Map.get(state, bucket, %{}), fn
        {:delete, key}, acc ->
          Map.delete(acc, key)

        %Cookie{} = cookie, acc ->
          Map.put(acc, cookie_key(cookie), cookie)
      end)

    Map.put(state, bucket, bucket_state)
  end

  defp cleanup_expired(state) do
    now = DateTime.utc_now()

    Map.new(state, fn {bucket, cookies} ->
      kept =
        Map.reject(cookies, fn {_key, cookie} ->
          expired?(cookie, now)
        end)

      {bucket, kept}
    end)
  end

  defp request_cookie_header(headers) do
    Enum.find_value(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "cookie", do: value

      [name, value] when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "cookie", do: value

      _other ->
        nil
    end)
  end

  defp parse_cookie_header(header, request) do
    uri = URI.parse(request.url)
    host = normalize_host(uri.host)
    path = default_cookie_path(request_path(uri))

    header
    |> String.split(";", trim: true)
    |> Enum.map(fn pair ->
      case String.split(String.trim(pair), "=", parts: 2) do
        [name, value] ->
          %Cookie{
            name: name,
            value: value,
            domain: host,
            host_only: true,
            path: path,
            secure: uri.scheme == "https"
          }

        _other ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_set_cookie(header, request) do
    uri = URI.parse(request.url)
    host = normalize_host(uri.host)
    request_path = request_path(uri)

    [cookie_part | attrs] =
      header
      |> String.split(";", trim: true)
      |> Enum.map(&String.trim/1)

    case String.split(cookie_part, "=", parts: 2) do
      [name, value] ->
        attrs
        |> cookie_attributes()
        |> build_response_cookie(name, value, host, request_path)

      _other ->
        nil
    end
  end

  defp normalize_cookie_input(%{} = cookie, request) do
    uri = URI.parse(request.url)
    host = normalize_host(uri.host)

    name = Map.get(cookie, :name, Map.get(cookie, "name"))
    value = Map.get(cookie, :value, Map.get(cookie, "value"))

    if is_binary(name) and is_binary(value) do
      domain =
        cookie
        |> Map.get(:domain, Map.get(cookie, "domain"))
        |> case do
          nil -> host
          value -> normalize_domain(value)
        end

      path =
        Map.get(cookie, :path, Map.get(cookie, "path")) || default_cookie_path(request_path(uri))

      expires_at = normalize_cookie_expiry(Map.get(cookie, :expires, Map.get(cookie, "expires")))

      %Cookie{
        name: name,
        value: value,
        domain: domain,
        host_only: is_nil(Map.get(cookie, :domain, Map.get(cookie, "domain"))),
        path: path,
        secure: truthy?(Map.get(cookie, :secure, Map.get(cookie, "secure"))),
        http_only: truthy?(Map.get(cookie, :http_only, Map.get(cookie, "httpOnly"))),
        same_site: Map.get(cookie, :same_site, Map.get(cookie, "sameSite")),
        expires_at: expires_at
      }
    end
  end

  defp normalize_cookie_input({name, value}, request) when is_binary(name) and is_binary(value) do
    uri = URI.parse(request.url)

    %Cookie{
      name: name,
      value: value,
      domain: normalize_host(uri.host),
      host_only: true,
      path: default_cookie_path(request_path(uri))
    }
  end

  defp normalize_cookie_input(_cookie, _request), do: nil

  defp cookie_matches?(%Cookie{} = cookie, host, path, secure?) do
    domain_match?(cookie, host) and path_match?(cookie.path, path) and
      (not cookie.secure or secure?) and
      not expired?(cookie, DateTime.utc_now())
  end

  defp domain_match?(%Cookie{host_only: true, domain: domain}, host), do: domain == host

  defp domain_match?(%Cookie{domain: domain}, host) do
    host == domain or String.ends_with?(host, "." <> domain)
  end

  defp path_match?(cookie_path, request_path) do
    String.starts_with?(request_path, cookie_path)
  end

  defp delete_cookie?(cookie, attr_map) do
    (cookie.value == "" and Map.has_key?(attr_map, "expires")) or
      case Map.get(attr_map, "max-age") do
        nil ->
          false

        "0" ->
          true

        value ->
          parse_integer(value)
          |> case do
            int when is_integer(int) and int <= 0 -> true
            _ -> false
          end
      end
  end

  defp expired?(%Cookie{expires_at: nil}, _now), do: false

  defp expired?(%Cookie{expires_at: %DateTime{} = expires_at}, %DateTime{} = now),
    do: DateTime.compare(expires_at, now) != :gt

  defp parse_expiry(attr_map) do
    case Map.get(attr_map, "max-age") do
      nil ->
        attr_map
        |> Map.get("expires")
        |> normalize_cookie_expiry()

      value ->
        case parse_integer(value) do
          int when is_integer(int) and int > 0 -> DateTime.add(DateTime.utc_now(), int, :second)
          _ -> nil
        end
    end
  end

  defp normalize_cookie_expiry(nil), do: nil

  defp normalize_cookie_expiry(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  defp normalize_cookie_expiry(value) when is_binary(value) do
    with {{year, month, day}, {hour, minute, second}} <-
           :httpd_util.convert_request_date(String.to_charlist(value)),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp normalize_cookie_expiry(_value), do: nil

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp default_cookie_path(""), do: "/"
  defp default_cookie_path("/"), do: "/"

  defp default_cookie_path(path) do
    path
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.join("/")
    |> case do
      "" -> "/"
      value -> value
    end
  end

  defp request_path(%URI{path: nil}), do: "/"
  defp request_path(%URI{path: ""}), do: "/"
  defp request_path(%URI{path: path}), do: path

  defp cookie_key(%Cookie{} = cookie), do: {cookie.domain, cookie.path, cookie.name}

  defp normalize_domain(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading(".")
    |> String.downcase()
  end

  defp normalize_host(nil), do: ""
  defp normalize_host(host), do: host |> to_string() |> String.downcase()

  defp fetch_metadata(metadata, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(metadata, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp clear_state(state, opts) do
    bucket = clear_bucket(opts)
    host = clear_host(opts)

    cond do
      is_nil(bucket) and is_nil(host) ->
        %{}

      is_binary(bucket) and is_nil(host) ->
        Map.delete(state, bucket)

      true ->
        clear_matching_cookies(state, bucket, host)
    end
  end

  defp clear_bucket(opts) do
    case Keyword.get(opts, :request) do
      %Request{} = request ->
        bucket_for(request)

      _other ->
        opts
        |> Keyword.get(:wireguard_ip_address)
        |> case do
          value when is_binary(value) and value != "" -> value
          _ -> Keyword.get(opts, :bucket)
        end
    end
  end

  defp clear_host(opts) do
    case Keyword.get(opts, :request) do
      %Request{} = request ->
        request.url |> URI.parse() |> Map.get(:host) |> normalize_host()

      _other ->
        case Keyword.get(opts, :host) do
          value when is_binary(value) and value != "" -> normalize_host(value)
          _ -> nil
        end
    end
  end

  defp clear_cookie_for_host?(_cookie, nil), do: true
  defp clear_cookie_for_host?(cookie, host), do: domain_match?(cookie, host)

  defp cookie_attributes(attrs) do
    Map.new(attrs, fn attr ->
      case String.split(attr, "=", parts: 2) do
        [key, val] -> {String.downcase(key), val}
        [key] -> {String.downcase(key), true}
      end
    end)
  end

  defp build_response_cookie(attr_map, name, value, host, request_path) do
    {domain, host_only} = cookie_domain(attr_map, host)

    cookie = %Cookie{
      name: name,
      value: value,
      domain: domain,
      host_only: host_only,
      path: Map.get(attr_map, "path") || default_cookie_path(request_path),
      secure: Map.has_key?(attr_map, "secure"),
      http_only: Map.has_key?(attr_map, "httponly"),
      same_site: Map.get(attr_map, "samesite"),
      expires_at: parse_expiry(attr_map)
    }

    if delete_cookie?(cookie, attr_map), do: {:delete, cookie_key(cookie)}, else: cookie
  end

  defp cookie_domain(attr_map, host) do
    case Map.get(attr_map, "domain") do
      nil -> {host, true}
      value -> {normalize_domain(value), false}
    end
  end

  defp clear_matching_cookies(state, bucket, host) do
    Map.new(state, fn {state_bucket, cookies} ->
      if is_nil(bucket) or bucket == state_bucket do
        {state_bucket,
         Map.reject(cookies, fn {_key, cookie} -> clear_cookie_for_host?(cookie, host) end)}
      else
        {state_bucket, cookies}
      end
    end)
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]
end
