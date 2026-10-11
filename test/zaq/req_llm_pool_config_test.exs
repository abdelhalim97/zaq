defmodule Zaq.ReqLLMPoolConfigTest do
  use ExUnit.Case, async: false

  @variables ["REQ_LLM_POOL_SIZE", "REQ_LLM_POOL_COUNT"]
  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    previous = Map.new(@variables, &{&1, System.get_env(&1)})
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  test "defaults and legacy overrides retain the per-origin connection budget" do
    assert pool() == [protocols: [:http1], size: 50, count: 1]
    System.put_env("REQ_LLM_POOL_COUNT", "8")
    assert pool() == [protocols: [:http1], size: 8, count: 1]
    System.put_env("REQ_LLM_POOL_SIZE", "3")
    assert pool() == [protocols: [:http1], size: 3, count: 1]
  end

  test "invalid capacity fails at startup for either variable" do
    for key <- @variables, value <- ["0", "-1", "", "abc", "2.5", "8garbage"] do
      System.put_env(key, value)
      assert_raise RuntimeError, ~r/must be a positive integer/, &pool/0
      System.delete_env(key)
    end
  end

  defp pool do
    config = Config.Reader.read!(@runtime, env: :test, target: :host)
    config[:req_llm][:finch][:pools][:default]
  end
end
