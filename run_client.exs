#!/usr/bin/env elixir

defmodule UrbanFleet.Client do
  def start do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║       🚗 SISTEMA CLIENTE URBANFLEET     ║
    ╚════════════════════════════════════════╝
    ¡Bienvenido a UrbanFleet!
    Escribe 'help' para ver los comandos disponibles.
    """)

    # Intentar conectar al servidor
    if Node.connect(:"server@localhost") do
      IO.puts("✅ Conectado al Servidor UrbanFleet.")
      case :rpc.call(:"server@localhost", Process, :whereis, [:server]) do
        pid when is_pid(pid) ->
          IO.puts("🖥️  Proceso remoto del servidor encontrado.")
          command_loop(pid, nil)

        _ ->
          IO.puts("⚠️ Proceso del servidor no encontrado. Asegúrate de que esté en ejecución.")
      end
    else
      IO.puts("❌ No se pudo conectar al nodo remoto (:\"server@localhost\")")
    end
  end

  # ============================================================
  # CLI LOOP
  # ============================================================

  # Public function for server RPC to push notifications to this client
  def notify(message) do
    IO.puts("\n" <> message)
    :ok
  end

  defp command_loop(pid, user \\ nil) do
    prompt =
      case user do
        %{role: :client, username: u} -> IO.ANSI.green() <> "[Cliente: #{u}] > " <> IO.ANSI.reset()
        %{role: :driver, username: u} -> IO.ANSI.yellow() <> "[Driver: #{u}] > " <> IO.ANSI.reset()
        %{role: r} -> IO.ANSI.cyan() <> "[#{Atom.to_string(r)}] > " <> IO.ANSI.reset()
        _ -> IO.ANSI.cyan() <> "[Invitado] > " <> IO.ANSI.reset()
      end

    input = IO.gets(prompt)

    case input do
      nil ->
        IO.puts("\n👋 Cerrando cliente...")
        :ok

      raw ->
        cmd = String.trim(raw)

        case cmd do
          "" ->
            command_loop(pid, user)

          "exit" ->
            IO.puts("👋 Desconectando cliente...")

          "help" ->
            show_help(user)
            command_loop(pid, user)

          _ ->
            # Enviar comando al servidor (ahora enviamos el estado local 'user' y esperamos {msg, new_state})
            case :rpc.call(:"server@localhost", GenServer, :call, [:server, {:remote_command, cmd, user}]) do
              {:ok, {response, new_state}} ->
                IO.puts(response)

                cond do
                  is_map(new_state) ->
                    # successful login/updated state -> register this client node for callbacks
                    :rpc.call(:"server@localhost", GenServer, :call, [:server, {:register_client, new_state, Node.self()}])
                    command_loop(pid, new_state)

                  new_state == :logout ->
                    # server indicated logout -> unregister and clear local state
                    if user && Map.get(user, :username) do
                      :rpc.call(:"server@localhost", GenServer, :call, [:server, {:unregister_client, user.username}])
                    end
                    command_loop(pid, nil)

                  true ->
                    command_loop(pid, user)
                end

              {:error, {response, _client_state}} ->
                IO.puts(response)
                command_loop(pid, user)

              {:badrpc, reason} ->
                IO.puts("⚠️ Error RPC: #{inspect(reason)}")
                command_loop(pid, user)

              other ->
                IO.inspect(other, label: "Respuesta desconocida del servidor")
                command_loop(pid, user)
            end
        end
    end
  end

  # ============================================================
  # HELP MENUS
  # ============================================================

  defp show_help(%{role: :client}) do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║          📱 COMANDOS DEL CLIENTE        ║
    ╚════════════════════════════════════════╝
    request <origin> <dest>        (or: request_trip origen=<loc> destino=<loc>) - Pedir viaje
    my_score      (or: score)                                            - Ver tu puntuación
    ranking       (or: rank)                                             - Ver ranking global
    disconnect                                                             - Desconectarse
    help                                                                   - Mostrar esta ayuda
    exit                                                                   - Cerrar sesión
    """)
  end

  defp show_help(%{role: :driver}) do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║          🚕 COMANDOS DEL DRIVER         ║
    ╚════════════════════════════════════════╝
    list_trips   (or: trips)        - View available trips
    accept_trip <id> (or: accept)   - Accept a trip
    cancel <id>   (or: cancel_trip)  - Cancel an accepted trip (penalización)
    my_score      (or: score)       - View your score
    ranking driver (or: rank driver)- View driver ranking
    disconnect                      - Disconnect
    help                            - Show this help
    exit                            - Exit session
    """)
  end

  defp show_help(nil) do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║         👋 BIENVENIDO A URBANFLEET      ║
    ╚════════════════════════════════════════╝
    connect <user> <pass> <client|driver> - Log in or register
    help                                  - Show this menu
    exit                                  - Close session
    """)
  end
end

UrbanFleet.Client.start()
