defmodule ExUndercover.Request do
  @enforce_keys [:url]
  defstruct method: :get,
            url: nil,
            headers: [],
            body: nil,
            browser_profile: :chrome_latest,
            proxy_tunnel: nil,
            metadata: %{}

  @type t :: %__MODULE__{
          method: atom(),
          url: String.t(),
          headers: [{binary(), binary()}],
          body: iodata() | nil,
          browser_profile: atom(),
          proxy_tunnel: binary() | nil,
          metadata: map()
        }

  @spec new(String.t(), keyword()) :: t()
  def new(url, opts \\ []) when is_binary(url) do
    %__MODULE__{
      url: url,
      method: Keyword.get(opts, :method, :get),
      headers: Keyword.get(opts, :headers, []),
      body: Keyword.get(opts, :body),
      browser_profile: Keyword.get(opts, :browser_profile, :chrome_latest),
      proxy_tunnel: Keyword.get(opts, :proxy_tunnel),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
