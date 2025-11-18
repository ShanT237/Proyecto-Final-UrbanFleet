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
          IO.puts("🖥️  Proceso remoto del servidor encontrado.\n")

          # Iniciar proceso listener en background
          listener_pid = spawn(fn -> notification_listener() end)
          Process.register(listener_pid, :notification_listener)

          command_loop(pid, nil)

        _ ->
          IO.puts("⚠️ Proceso del servidor no encontrado. Asegúrate de que esté en ejecución.")
      end
    else
      IO.puts("❌ No se pudo conectar al nodo remoto (:\"server@localhost\")")
    end
  end

  # ============================================================
  # NOTIFICATION LISTENER (corre en background)
  # ============================================================

  defp notification_listener do
    receive do
      {:notification, message} ->
        IO.write("\r" <> String.duplicate(" ", 80) <> "\r")  # Limpiar línea
        IO.puts(message)
        notification_listener()

      :stop ->
        :ok
    end
  end

  # ============================================================
  # PUBLIC API para que el servidor envíe notificaciones
  # ============================================================

  def notify(message) do
    case Process.whereis(:notification_listener) do
      nil -> :ok
      pid -> send(pid, {:notification, message})
    end
    :ok
  end

  # ============================================================
  # CLI LOOP
  # ============================================================

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
            if Process.whereis(:notification_listener) do
              send(:notification_listener, :stop)
            end
            :ok

          "help" ->
            show_help(user)
            command_loop(pid, user)

          _ ->
            # Enviar comando al servidor
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
    request <origin> <dest>        - Solicitar viaje
    my_score      (or: score)      - Ver tu puntuación
    ranking       (or: rank)       - Ver ranking global
    disconnect                     - Desconectarse
    help                           - Mostrar esta ayuda
    exit                           - Cerrar sesión
    """)
  end

  defp show_help(%{role: :driver}) do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║          🚕 COMANDOS DEL DRIVER         ║
    ╚════════════════════════════════════════╝
    list_trips   (or: trips)        - Ver viajes disponibles
    accept_trip <id> (or: accept)   - Aceptar viaje
    cancel <id>   (or: cancel_trip) - Cancelar viaje aceptado
    my_score      (or: score)       - Ver tu puntuación
    ranking driver (or: rank driver)- Ver ranking conductores
    disconnect                      - Desconectarse
    help                            - Mostrar esta ayuda
    exit                            - Cerrar sesión
    """)
  end

  defp show_help(nil) do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║         👋 BIENVENIDO A URBANFLEET      ║
    ╚════════════════════════════════════════╝
    connect <user> <pass> <client|driver> - Log in o registrar
    help                                  - Mostrar este menú
    exit                                  - Cerrar sesión
    """)
  end
end

UrbanFleet.Client.start()
