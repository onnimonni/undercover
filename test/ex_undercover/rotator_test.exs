defmodule ExUndercover.RotatorTest do
  use ExUnit.Case, async: false

  alias ExUndercover.Rotator

  test "debounces challenge notifications per host" do
    {:ok, pid} = Rotator.start_link(name: nil, host_debounce_ms: 5)

    assert Rotator.should_rotate?(pid, "example.test")
    assert :ok = Rotator.notify(pid, "example.test", :challenge, %{reason: "cf"})
    refute Rotator.should_rotate?(pid, "example.test")

    Process.sleep(10)
    assert Rotator.should_rotate?(pid, "example.test")

    assert [%{classification: :challenge, host: "example.test", reason: "cf"}] =
             Rotator.recent(pid)
  end

  test "ignores non-rotation classifications for debounce state" do
    {:ok, pid} = Rotator.start_link(name: nil, host_debounce_ms: 60_000)

    assert :ok = Rotator.notify(pid, "example.test", :ok, %{reason: "fine"})
    assert Rotator.should_rotate?(pid, "example.test")
    assert [%{classification: :ok, reason: "fine"}] = Rotator.recent(pid)
  end

  test "rate limited responses also update rotation state" do
    {:ok, pid} = Rotator.start_link(name: nil, host_debounce_ms: 60_000)

    assert :ok = Rotator.notify(pid, "example.test", :rate_limited, %{"reason" => "429"})
    refute Rotator.should_rotate?(pid, "example.test")
    assert [%{classification: :rate_limited, reason: "429"}] = Rotator.recent(pid)
  end
end
