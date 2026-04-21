defmodule ExUndercover.Capture.ClientHello do
  @moduledoc """
  Capture a real Chrome TLS ClientHello against a local TCP listener.
  """

  alias ExUndercover.Profile
  alias ExUndercover.Solver.Chrome

  @default_timeout_ms 15_000
  @capture_host "capture.local"

  @spec capture(keyword()) :: {:ok, map()} | {:error, term()}
  def capture(opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with {:ok, browser} <- Chrome.browser_info(opts),
         {:ok, profile} <- solver_profile(opts),
         {:ok, listener} <- listen(),
         {:ok, port} <- :inet.port(listener),
         task = Task.async(fn -> accept_and_capture(listener, timeout) end),
         {:ok, session} <- launch_capture_browser(browser.path, profile, port, opts),
         {:ok, capture} <- await_capture(task, timeout) do
      cleanup_session(session)
      {:ok, Map.merge(capture, browser_metadata(browser, profile, port))}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp browser_metadata(browser, profile, port) do
    %{
      browser_path: browser.path,
      browser_version: browser.version,
      browser_major: browser.major,
      profile_id: profile.id,
      profile_version: profile.version,
      capture_host: @capture_host,
      capture_port: port
    }
  end

  defp solver_profile(opts) do
    opts
    |> Keyword.get(:browser_profile, :chrome_latest)
    |> Profile.resolve()
    |> then(&{:ok, &1})
  rescue
    error -> {:error, {:profile_resolve_failed, Exception.message(error)}}
  end

  defp listen do
    :gen_tcp.listen(0, [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1}
    ])
  end

  defp accept_and_capture(listener, timeout) do
    with {:ok, socket} <- :gen_tcp.accept(listener, timeout),
         {:ok, record} <- recv_tls_record(socket, timeout) do
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
      {:ok, parse_client_hello(record)}
    else
      {:error, reason} ->
        :gen_tcp.close(listener)
        {:error, reason}
    end
  end

  defp recv_tls_record(socket, timeout) do
    with {:ok, header} <- :gen_tcp.recv(socket, 5, timeout) do
      <<_type, _version::16, length::16>> = header

      with {:ok, body} <- :gen_tcp.recv(socket, length, timeout) do
        {:ok, header <> body}
      end
    end
  end

  defp parse_client_hello(
         record = <<22, legacy_version::16, _record_len::16, 1, hello_len::24, hello::binary>>
       ) do
    <<client_version::16, random::binary-size(32), rest::binary>> =
      binary_part(hello, 0, hello_len)

    <<session_len, after_session::binary>> = rest
    <<_session::binary-size(^session_len), after_cipher_len::binary>> = after_session
    <<cipher_len::16, after_ciphers::binary>> = after_cipher_len
    <<cipher_bytes::binary-size(^cipher_len), after_comp_len::binary>> = after_ciphers
    <<comp_len, after_comp::binary>> = after_comp_len
    <<_compression::binary-size(^comp_len), ext_block::binary>> = after_comp
    <<ext_len::16, ext_bytes::binary-size(ext_len), _rest::binary>> = ext_block

    extensions = parse_extensions(ext_bytes, [])
    groups = parse_supported_groups(extensions)
    ec_point_formats = parse_ec_point_formats(extensions)

    %{
      record_version: tls_version_string(legacy_version),
      client_version: tls_version_string(client_version),
      random: Base.encode16(random, case: :lower),
      cipher_suites: parse_u16_list(cipher_bytes),
      extension_ids: Enum.map(extensions, & &1.id),
      extensions: Enum.map(extensions, &Map.take(&1, [:id, :name])),
      sni: extension_value(extensions, 0, :sni),
      alpn: extension_value(extensions, 16, :alpn) || [],
      supported_groups: groups,
      ec_point_formats: ec_point_formats,
      ja3: build_ja3(client_version, cipher_bytes, extensions, groups, ec_point_formats),
      ja3_hash:
        build_ja3(client_version, cipher_bytes, extensions, groups, ec_point_formats)
        |> then(&:crypto.hash(:md5, &1))
        |> Base.encode16(case: :lower),
      client_hello_hex: Base.encode16(record, case: :lower)
    }
  end

  defp parse_client_hello(other), do: {:unexpected_record, Base.encode16(other, case: :lower)}

  defp parse_extensions(<<>>, acc), do: Enum.reverse(acc)

  defp parse_extensions(<<id::16, len::16, data::binary-size(len), rest::binary>>, acc) do
    parse_extensions(rest, [extension_entry(id, data) | acc])
  end

  defp extension_entry(
         0,
         <<_list_len::16, 0, sni_len::16, sni::binary-size(sni_len), _rest::binary>>
       ) do
    %{id: 0, name: "server_name", sni: sni}
  end

  defp extension_entry(16, <<list_len::16, list::binary-size(list_len), _rest::binary>>) do
    %{id: 16, name: "alpn", alpn: parse_alpn_list(list, [])}
  end

  defp extension_entry(10, data), do: %{id: 10, name: "supported_groups", raw: data}
  defp extension_entry(11, data), do: %{id: 11, name: "ec_point_formats", raw: data}
  defp extension_entry(id, _data), do: %{id: id, name: extension_name(id)}

  defp parse_alpn_list(<<>>, acc), do: Enum.reverse(acc)

  defp parse_alpn_list(<<len, value::binary-size(len), rest::binary>>, acc) do
    parse_alpn_list(rest, [value | acc])
  end

  defp parse_supported_groups(extensions) do
    case Enum.find(extensions, &(&1.id == 10)) do
      %{raw: <<len::16, groups::binary-size(len), _rest::binary>>} -> parse_u16_list(groups)
      _ -> []
    end
  end

  defp parse_ec_point_formats(extensions) do
    case Enum.find(extensions, &(&1.id == 11)) do
      %{raw: <<len, formats::binary-size(len), _rest::binary>>} -> :binary.bin_to_list(formats)
      _ -> []
    end
  end

  defp build_ja3(version, cipher_bytes, extensions, groups, ec_point_formats) do
    [
      Integer.to_string(version),
      join_dash(parse_u16_list(cipher_bytes)),
      join_dash(Enum.map(extensions, & &1.id)),
      join_dash(groups),
      join_dash(ec_point_formats)
    ]
    |> Enum.join(",")
  end

  defp join_dash(list), do: list |> Enum.map(&Integer.to_string/1) |> Enum.join("-")

  defp parse_u16_list(binary), do: parse_u16_list(binary, [])
  defp parse_u16_list(<<>>, acc), do: Enum.reverse(acc)
  defp parse_u16_list(<<value::16, rest::binary>>, acc), do: parse_u16_list(rest, [value | acc])

  defp extension_value(extensions, id, key) do
    case Enum.find(extensions, &(&1.id == id)) do
      nil -> nil
      ext -> Map.get(ext, key)
    end
  end

  defp extension_name(0), do: "server_name"
  defp extension_name(5), do: "status_request"
  defp extension_name(10), do: "supported_groups"
  defp extension_name(11), do: "ec_point_formats"
  defp extension_name(13), do: "signature_algorithms"
  defp extension_name(16), do: "alpn"
  defp extension_name(18), do: "signed_certificate_timestamp"
  defp extension_name(21), do: "padding"
  defp extension_name(23), do: "extended_master_secret"
  defp extension_name(27), do: "compress_certificate"
  defp extension_name(34), do: "delegated_credential"
  defp extension_name(35), do: "session_ticket"
  defp extension_name(43), do: "supported_versions"
  defp extension_name(45), do: "psk_key_exchange_modes"
  defp extension_name(51), do: "key_share"
  defp extension_name(65281), do: "renegotiation_info"
  defp extension_name(id), do: "extension_#{id}"

  defp tls_version_string(0x0301), do: "tls1.0"
  defp tls_version_string(0x0302), do: "tls1.1"
  defp tls_version_string(0x0303), do: "tls1.2"
  defp tls_version_string(0x0304), do: "tls1.3"
  defp tls_version_string(other), do: "0x" <> Integer.to_string(other, 16)

  defp launch_capture_browser(browser_path, profile, port, opts) do
    user_data_dir =
      Keyword.get_lazy(opts, :user_data_dir, fn ->
        Path.join(
          System.tmp_dir!(),
          "ex_undercover-capture-#{System.unique_integer([:positive])}"
        )
      end)

    File.mkdir_p!(user_data_dir)

    args =
      [
        "--headless=new",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-networking",
        "--disable-sync",
        "--disable-blink-features=AutomationControlled",
        "--no-sandbox",
        "--host-resolver-rules=MAP #{@capture_host} 127.0.0.1",
        "--user-data-dir=#{user_data_dir}",
        "--user-agent=#{solver_user_agent(profile)}",
        "https://#{@capture_host}:#{port}/"
      ]

    port_ref =
      Port.open({:spawn_executable, browser_path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        :hide,
        args: args
      ])

    {:ok,
     %{
       port_ref: port_ref,
       os_pid: Keyword.get(Port.info(port_ref), :os_pid),
       user_data_dir: user_data_dir
     }}
  rescue
    error -> {:error, {:capture_launch_failed, Exception.message(error)}}
  end

  defp await_capture(task, timeout) do
    Task.await(task, timeout + 1_000)
  catch
    :exit, reason -> {:error, {:capture_timeout, reason}}
  end

  defp cleanup_session(session) do
    port_info = Port.info(session.port_ref)

    if port_info != nil do
      Port.close(session.port_ref)
    end

    if is_integer(session.os_pid) do
      System.cmd("kill", ["-TERM", Integer.to_string(session.os_pid)], stderr_to_stdout: true)
    end

    File.rm_rf(session.user_data_dir)
    :ok
  rescue
    _error -> :ok
  end

  defp solver_user_agent(profile) do
    Enum.find_value(profile.headers, fn
      {"user-agent", value} -> value
      _ -> nil
    end)
  end
end
