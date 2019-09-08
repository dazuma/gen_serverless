defmodule Demo.Server do
  use GenServerless

  import Demo.LogWriter

  def init(arg) when is_number(arg) do
    log("[DemoServer init] initial=#{inspect(arg)}")
    {:ok, %{acc: arg, count: 0}}
  end

  def init(_), do: init(0)

  def handle_cast(val, %{acc: acc, count: count}) do
    acc = acc + val
    count = count + 1
    log("[DemoServer cast] val=#{inspect(val)} acc=#{inspect(acc)} count=#{inspect(count)}")
    {:noreply, %{acc: acc, count: count}}
  end

  def terminate(reason, %{acc: acc, count: count}) do
    log(
      "[DemoServer terminate] reason=#{inspect(reason)} final=#{inspect(acc)} count=#{
        inspect(count)
      }"
    )

    :ok
  end
end
