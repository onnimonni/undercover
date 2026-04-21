defmodule ExUndercover.CookieJarTest do
  use ExUnit.Case, async: false

  alias ExUndercover.CookieJar
  alias ExUndercover.Request

  setup do
    {:ok, pid} = CookieJar.start_link(name: nil)
    %{jar: pid}
  end

  test "stores response cookies per wireguard bucket and host", %{jar: jar} do
    request =
      Request.new("https://www.example.test/path",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    other_bucket_request =
      Request.new("https://www.example.test/path",
        metadata: %{"wireguard_ip_address" => "10.0.0.3"}
      )

    assert :ok =
             CookieJar.store_response(jar, request, [
               {"set-cookie", "sid=abc; Path=/; Domain=example.test; Secure"}
             ])

    assert CookieJar.cookie_header(jar, request) == "sid=abc"
    assert CookieJar.cookie_header(jar, other_bucket_request) == nil
  end

  test "seeds explicit request cookies and clears by bucket", %{jar: jar} do
    request =
      Request.new("https://www.example.test/path",
        headers: [{"cookie", "manual=1"}],
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    assert :ok = CookieJar.seed_request_cookies(jar, request)
    assert CookieJar.cookie_header(jar, %Request{request | headers: []}) == "manual=1"

    assert :ok = CookieJar.clear(jar, wireguard_ip_address: "10.0.0.2")
    assert CookieJar.cookie_header(jar, %Request{request | headers: []}) == nil
  end

  test "clears cookies for one host without wiping the whole bucket", %{jar: jar} do
    first =
      Request.new("https://www.example.test/a", metadata: %{"wireguard_ip_address" => "10.0.0.2"})

    second =
      Request.new("https://api.example.test/a", metadata: %{"wireguard_ip_address" => "10.0.0.2"})

    assert :ok = CookieJar.store_response(jar, first, [{"set-cookie", "first=1; Path=/"}])
    assert :ok = CookieJar.store_response(jar, second, [{"set-cookie", "second=1; Path=/"}])

    assert CookieJar.cookie_header(jar, first) == "first=1"
    assert CookieJar.cookie_header(jar, second) == "second=1"

    assert :ok = CookieJar.clear(jar, wireguard_ip_address: "10.0.0.2", host: "www.example.test")

    assert CookieJar.cookie_header(jar, first) == nil
    assert CookieJar.cookie_header(jar, second) == "second=1"
  end

  test "stores secure solver cookies and respects scheme and path matching", %{jar: jar} do
    request =
      Request.new("https://shop.example.test/checkout/start",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    same_host_path =
      Request.new("https://shop.example.test/checkout/confirm",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    wrong_scheme =
      Request.new("http://shop.example.test/checkout/confirm",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    wrong_path =
      Request.new("https://shop.example.test/account",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    assert :ok =
             CookieJar.store_cookies(jar, request, [
               %{
                 name: "solver",
                 value: "1",
                 domain: "example.test",
                 path: "/checkout",
                 secure: true
               }
             ])

    assert CookieJar.cookie_header(jar, same_host_path) == "solver=1"
    assert CookieJar.cookie_header(jar, wrong_scheme) == nil
    assert CookieJar.cookie_header(jar, wrong_path) == nil
  end

  test "deletes cookies when set-cookie expires them", %{jar: jar} do
    request =
      Request.new("https://www.example.test/path",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    assert :ok = CookieJar.store_response(jar, request, [{"set-cookie", "sid=abc; Path=/"}])
    assert CookieJar.cookie_header(jar, request) == "sid=abc"

    assert :ok =
             CookieJar.store_response(jar, request, [
               {"set-cookie", "sid=; Path=/; Max-Age=0"}
             ])

    assert CookieJar.cookie_header(jar, request) == nil
  end

  test "clears via request scope and can wipe the whole jar", %{jar: jar} do
    request =
      Request.new("https://www.example.test/path",
        metadata: %{"wireguard_ip_address" => "10.0.0.2"}
      )

    other =
      Request.new("https://api.example.test/path",
        metadata: %{"wireguard_ip_address" => "10.0.0.3"}
      )

    assert :ok = CookieJar.store_response(jar, request, [{"set-cookie", "one=1; Path=/"}])
    assert :ok = CookieJar.store_response(jar, other, [{"set-cookie", "two=2; Path=/"}])

    assert :ok = CookieJar.clear(jar, request: request)
    assert CookieJar.cookie_header(jar, request) == nil
    assert CookieJar.cookie_header(jar, other) == "two=2"

    assert :ok = CookieJar.clear(jar)
    assert CookieJar.cookie_header(jar, other) == nil
  end
end
