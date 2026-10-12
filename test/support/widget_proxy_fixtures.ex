defmodule Zaq.WidgetProxyFixtures do
  @moduledoc false
  use GenServer

  # A real TLS -> HTTP tunnel, including WebSocket upgrades. Test-only; based on
  # the package host smoke fixture. Forwarding headers are overwritten at ingress.
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(opts) do
    {:ok, listener} =
      :ssl.listen(Keyword.get(opts, :port, 0), [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        certfile: String.to_charlist(opts[:certfile]),
        keyfile: String.to_charlist(opts[:keyfile])
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    acceptor = spawn_link(fn -> accept(listener, opts, port) end)
    {:ok, %{listener: listener, acceptor: acceptor, port: port}}
  end

  @impl true
  def handle_call(:port, _, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_, state) do
    :ssl.close(state.listener)
    Process.exit(state.acceptor, :shutdown)
  end

  defp accept(listener, opts, public_port) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        pid =
          spawn_link(fn ->
            receive do
              {:socket, owned} -> proxy(owned, opts, public_port)
            end
          end)

        :ok = :ssl.controlling_process(socket, pid)
        send(pid, {:socket, socket})
        accept(listener, opts, public_port)

      {:error, :closed} ->
        :ok
    end
  end

  defp proxy(socket, opts, public_port) do
    with {:ok, tls} <- :ssl.handshake(socket, 5_000),
         {:ok, head} <- headers(tls, ""),
         {:ok, tcp} <-
           :gen_tcp.connect({127, 0, 0, 1}, opts[:backend_port], [:binary, active: false], 5_000) do
      [head, body] = String.split(head, "\r\n\r\n", parts: 2)
      [request | headers] = String.split(head, "\r\n")

      headers =
        Enum.reject(
          headers,
          &String.starts_with?(String.downcase(&1), ["x-forwarded-", "forwarded:"])
        )

      headers = connection_headers(headers)

      forwarded = ["x-forwarded-proto: https", "x-forwarded-host: localhost"]

      forwarded =
        if opts[:forwarded_port] == :omit,
          do: forwarded,
          else: forwarded ++ ["x-forwarded-port: #{public_port}"]

      :ok =
        :gen_tcp.send(
          tcp,
          Enum.join([request | headers ++ forwarded], "\r\n") <> "\r\n\r\n" <> body
        )

      :ssl.setopts(tls, active: :once)
      :inet.setopts(tcp, active: :once)
      relay(tls, tcp)
      :gen_tcp.close(tcp)
      :ssl.close(tls)
    end
  end

  defp connection_headers(headers) do
    if Enum.any?(headers, &(String.downcase(&1) == "upgrade: websocket")) do
      headers
    else
      [
        "connection: close"
        | Enum.reject(headers, &String.starts_with?(String.downcase(&1), "connection:"))
      ]
    end
  end

  defp headers(socket, acc) when byte_size(acc) <= 32_768 do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, bytes} <- :ssl.recv(socket, 0, 5_000), do: headers(socket, acc <> bytes)
    end
  end

  defp headers(_, _), do: {:error, :headers_too_large}

  defp relay(tls, tcp) do
    receive do
      {:ssl, ^tls, bytes} ->
        :gen_tcp.send(tcp, bytes)
        :ssl.setopts(tls, active: :once)
        relay(tls, tcp)

      {:tcp, ^tcp, bytes} ->
        :ssl.send(tls, bytes)
        :inet.setopts(tcp, active: :once)
        relay(tls, tcp)

      {:ssl_closed, ^tls} ->
        :ok

      {:tcp_closed, ^tcp} ->
        :ok

      {:ssl_error, ^tls, _} ->
        :ok

      {:tcp_error, ^tcp, _} ->
        :ok
    end
  end
end
