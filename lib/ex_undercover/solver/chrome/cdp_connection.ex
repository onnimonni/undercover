defmodule ExUndercover.Solver.Chrome.CDPConnection do
  use WebSockex

  def start_link(url, owner) do
    WebSockex.start(url, __MODULE__, %{owner: owner})
  end

  def send_command(pid, payload) do
    WebSockex.send_frame(pid, {:text, Jason.encode!(payload)})
  end

  @impl true
  def handle_frame({:text, message}, state) do
    case Jason.decode(message) do
      {:ok, payload} -> send(state.owner, {:cdp_frame, self(), payload})
      {:error, reason} -> send(state.owner, {:cdp_decode_error, self(), reason, message})
    end

    {:ok, state}
  end

  @impl true
  def handle_disconnect(disconnect_map, state) do
    send(state.owner, {:cdp_disconnect, self(), disconnect_map})
    {:ok, state}
  end
end
