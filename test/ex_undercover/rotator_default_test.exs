defmodule ExUndercover.RotatorDefaultTest do
  use ExUnit.Case, async: false

  alias ExUndercover.Rotator

  test "supports the default registered server api" do
    unique_host = "default-#{System.unique_integer([:positive])}.test"

    assert :ok = Rotator.notify(unique_host, :challenge, %{reason: "cf"})
    refute Rotator.should_rotate?(unique_host)

    assert [%{host: ^unique_host, classification: :challenge, reason: "cf"} | _rest] =
             Rotator.recent()
  end
end
