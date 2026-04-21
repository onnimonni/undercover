defmodule ExUndercover.Profile.Chrome147 do
  alias ExUndercover.BrowserProfile

  @doc """
  Latest Chrome stable profile verified from Google's April 15, 2026 release.
  """
  @spec profile() :: BrowserProfile.t()
  def profile do
    %BrowserProfile{
      id: :chrome_147,
      browser: :chrome,
      version: "147.0.7727.101/102",
      platform: :linux,
      headers: [
        {"sec-ch-ua", ~s("Chromium";v="147", "Not.A/Brand";v="24", "Google Chrome";v="147")},
        {"sec-ch-ua-mobile", "?0"},
        {"sec-ch-ua-platform", ~s("Linux")},
        {"upgrade-insecure-requests", "1"},
        {"user-agent",
         "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"},
        {"accept-language", "en-US,en;q=0.9"},
        {"accept",
         "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"},
        {"sec-fetch-site", "none"},
        {"sec-fetch-mode", "navigate"},
        {"sec-fetch-user", "?1"},
        {"sec-fetch-dest", "document"},
        {"accept-encoding", "gzip, deflate, br, zstd"},
        {"priority", "u=0, i"}
      ],
      transport: %{
        tls: %{
          implementation: :rust_nif,
          source: :captured_profile,
          notes: "TLS extension ordering and HTTP/2 settings live in the Rust transport."
        },
        http2: %{
          implementation: :rust_nif,
          source: :captured_profile
        }
      }
    }
  end
end
