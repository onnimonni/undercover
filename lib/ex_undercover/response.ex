defmodule ExUndercover.Response do
  @enforce_keys [:status, :headers, :body]
  defstruct status: 0,
            headers: [],
            body: "",
            browser_profile: nil,
            remote_address: nil,
            diagnostics: %{}

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: [{binary(), binary()}],
          body: binary(),
          browser_profile: atom() | nil,
          remote_address: binary() | nil,
          diagnostics: map()
        }
end
