defmodule UrbanFleet.Server do
  use GenServer
  require Logger

  # ==============================
  # API PÚBLICA
  # ==============================

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: :server)
  end

  def start_cli do
    if Process.whereis(:server) do
      GenServer.cast(:server, :start_cli)
    else
      # 🔁 reintenta hasta que el proceso esté disponible
      spawn(fn ->
        :timer.sleep(200)
        start_cli()
      end)
    end
  end

  # ==============================
  # CALLBACKS DEL SERVIDOR
  # ==============================

  @impl true
  def init(_) do
    Logger.info("Servidor UrbanFleet iniciado")
    {:ok, %{current_user: nil, sessions: %{}}}
  end

  @impl true
  def handle_cast(:start_cli, state) do
    # Lanza la interfaz de administración local
    spawn(fn ->
      Process.sleep(400)
      show_server_banner()
      server_cli_loop()
    end)

    {:noreply, state}
  end

  # --- Helper definido temprano para evitar error de referencia ---
  defp format_datetime(dt) when is_struct(dt, DateTime) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  # Reemplazamos el handler de llamadas remotas para aceptar el estado del cliente
  def handle_call({:remote_command, input, client}, _from, state) do
    input = String.trim(input)

    case process_remote_command(input, client) do
      {:ok, msg, new_client} ->
        {:reply, {:ok, {msg, new_client}}, state}

      {:error, msg, client_state} ->
        {:reply, {:error, {msg, client_state}}, state}
    end
  end

  # Registrar/dar de baja nodos clientes para que el servidor pueda enviar notificaciones
  @impl true
  def handle_call({:register_client, %{username: username} = _user_map, client_node}, _from, state) do
    sessions = Map.put(state.sessions, username, client_node)
    Logger.info("Cliente registrado: #{username} en #{inspect(client_node)}")
    {:reply, :ok, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:unregister_client, username}, _from, state) do
    sessions = Map.delete(state.sessions, username)
    Logger.info("Cliente dado de baja: #{username}")
    {:reply, :ok, %{state | sessions: sessions}}
  end

  @impl true
  def handle_info({:new_client, pid}, state) do
    Logger.info("Nuevo cliente conectado: #{inspect(pid)}")
    {:noreply, state}
  end

  # Notificaciones desde procesos Trip
  @impl true
  def handle_info({:trip_completed, trip_state}, state) do
    msg = "✅ Viaje completado: #{trip_state.id} | Cliente: #{trip_state.client} | Conductor: #{trip_state.driver}"
    IO.puts("\n" <> msg)

    Logger.info("Enviando notificación de finalización al cliente: #{trip_state.client}")
    notify_user_by_name(trip_state.client, "\n✅ Tu viaje #{trip_state.id} fue completado exitosamente. Conductor: #{trip_state.driver}\n+10 puntos ganados! 🎉\n", state)

    Logger.info("Enviando notificación de finalización al conductor: #{trip_state.driver}")
    notify_user_by_name(trip_state.driver, "\n✅ Completaste el viaje #{trip_state.id}. Cliente: #{trip_state.client}\n+15 puntos ganados! 💰\n", state)

    {:noreply, state}
  end

  @impl true
  def handle_info({:trip_expired, trip_state}, state) do
    msg = "⚠️ Viaje expirado: #{trip_state.id} | Cliente: #{trip_state.client} | Origen: #{trip_state.origin} → Destino: #{trip_state.destination}"
    IO.puts("\n" <> msg)

    Logger.info("Enviando notificación de expiración al cliente: #{trip_state.client}")
    notify_user_by_name(trip_state.client, "\n⚠️ Tu viaje #{trip_state.id} expiró sin conductor.\nRuta: #{trip_state.origin} → #{trip_state.destination}\nPuedes solicitar uno nuevo.\n", state)

    {:noreply, state}
  end

  @impl true
  def handle_info({:trip_cancelled, trip_state}, state) do
    msg = "🛑 Viaje cancelado: #{trip_state.id} | Cliente: #{trip_state.client} | Conductor: #{trip_state.driver}"
    IO.puts("\n" <> msg)

    Logger.info("Enviando notificación de cancelación al cliente: #{trip_state.client}")
    notify_user_by_name(trip_state.client, "\n🛑 Tu viaje #{trip_state.id} fue cancelado por el conductor #{trip_state.driver}.\nPuedes solicitar un nuevo viaje.\n", state)

    Logger.info("Enviando notificación de cancelación al conductor: #{trip_state.driver}")
    notify_user_by_name(trip_state.driver, "\n🛑 Cancelaste el viaje #{trip_state.id}.\n⚠️  Penalización aplicada: -10 puntos\n", state)

    {:noreply, state}
  end

  # Actualizaciones de "tick" desde viajes: ms restantes (notificar a cliente y conductor si están conectados)
  @impl true
  def handle_info({:trip_tick, trip_id, remaining_ms}, state) do
    {:noreply, state}
  end

  # ==============================
  # BUCLE DEL CLI
  # ==============================

  defp cli_loop(current_user) do
    prompt =
      case current_user do
        %{role: :admin} ->
          IO.ANSI.cyan() <> "[servidor-admin] > " <> IO.ANSI.reset()

        %{username: u, role: r} ->
          IO.ANSI.green() <> "[#{u}@#{Atom.to_string(r)}] > " <> IO.ANSI.reset()

        _ ->
          IO.ANSI.cyan() <> "[invitado] > " <> IO.ANSI.reset()
      end

    IO.write(prompt)

    case IO.gets("") do
      :eof ->
        IO.puts("\n👋 Saliendo del servidor...")

      {:error, reason} ->
        IO.puts("⚠️ Error leyendo entrada: #{inspect(reason)}")
        cli_loop(current_user)

      input ->
        input
        |> String.trim()
        |> process_command(current_user)
        |> case do
          {:continue, new_user} -> cli_loop(new_user)
          :exit -> IO.puts("🖥️ Servidor detenido.")
        end
    end
  end

  # ==============================
  # PROCESAMIENTO DE COMANDOS
  # ==============================

  defp process_command("", user), do: {:continue, user}

  defp process_command("help", user) do
    cond do
      is_nil(user) -> show_guest_help()
      user.role == :admin -> show_admin_help()
      user.role == :client -> show_client_help()
      user.role == :driver -> show_driver_help()
      true -> show_guest_help()
    end

    {:continue, user}
  end

  defp process_command("help_admin", user) do
    show_admin_help()
    {:continue, user}
  end

  defp process_command("exit", _), do: :exit

  # --- COMANDOS DEL SERVIDOR (ADMIN) ---
  defp process_command("add_zone " <> zone, user) do
    UrbanFleet.Location.add_location(String.trim(zone))
    IO.puts("✅ Zona '#{zone}' agregada correctamente.")
    {:continue, user}
  end

  defp process_command("list_zones", user) do
    UrbanFleet.show_locations()
    {:continue, user}
  end

  defp process_command("show_stats", user) do
    UrbanFleet.show_stats()
    {:continue, user}
  end

  defp process_command("show_users", user) do
    IO.puts("\n📋 Usuarios registrados:\n")
    users = :sys.get_state(UrbanFleet.UserManager)

    users
    |> Map.values()
    |> Enum.each(fn u ->
      IO.puts("• #{u.username} (#{u.role}) - #{u.score} puntos")
    end)

    {:continue, user}
  end

  # ==============================
  # PROCESAMIENTO DE COMANDOS REMOTOS (RPC desde clientes)
  # ==============================

  # Alias / comandos cortos
  defp process_remote_command("request " <> args, client), do: process_remote_command("request_trip " <> args, client)
  defp process_remote_command("accept " <> id, client), do: process_remote_command("accept_trip " <> id, client)
  defp process_remote_command("trips", client), do: process_remote_command("list_trips", client)
  defp process_remote_command("score", client), do: process_remote_command("my_score", client)
  defp process_remote_command("rank", client), do: process_remote_command("ranking", client)
  defp process_remote_command("rank " <> role, client) when role in ["client", "driver"], do: process_remote_command("ranking " <> role, client)
  defp process_remote_command("cancel " <> id, client), do: process_remote_command("cancel_trip " <> id, client)
  defp process_remote_command("zones", client), do: process_remote_command("list_zones", client)

  defp process_remote_command("connect " <> args, nil) do
    case String.split(args) do
      [username, password, role] when role in ["client", "driver"] ->
        role_atom = String.to_atom(role)

        case UrbanFleet.UserManager.register_or_login(username, password, role_atom) do
          {:ok, :registered, user} ->
            {:ok, "✨ Registrado #{username} como #{role}.", %{username: username, role: role_atom}}

          {:ok, :logged_in, user} ->
            {:ok, "✅ Bienvenido de nuevo #{username}!", %{username: username, role: role_atom}}

          {:error, :invalid_password} ->
            {:error, "❌ Contraseña incorrecta.", nil}
        end

      _ ->
        {:error, "✗ Uso: connect <usuario> <contraseña> <client|driver>", nil}
    end
  end

  # list_zones -> para cualquier usuario conectado
  defp process_remote_command("list_zones", user) do
    zones = UrbanFleet.Location.list_locations()

    header = "\n📍 ZONAS DISPONIBLES\n" <> String.duplicate("═", 40) <> "\n"
    body = Enum.map_join(zones, "\n", fn zone -> "  • #{zone}" end)

    {:ok, header <> body <> "\n", user}
  end

  # cancel_trip -> para clientes (cancelar antes de que el conductor acepte)
  defp process_remote_command("cancel_trip " <> trip_id, %{role: :client, username: username} = user) do
    trip_id = String.trim(trip_id)

    # Primero verificar si el viaje existe
    case Registry.lookup(UrbanFleet.TripRegistry, trip_id) do
      [] ->
        {:error, "⚠️ El viaje #{trip_id} no existe o ya finalizó.", user}

      [{pid, _}] ->
        if Process.alive?(pid) do
          case UrbanFleet.Trip.cancel_trip_by_client(trip_id, username) do
            {:ok, _trip} ->
              {:ok, "🛑 Viaje #{trip_id} cancelado exitosamente.", user}

            {:error, :cannot_cancel} ->
              {:error, "⚠️ No puedes cancelar este viaje (ya tiene conductor asignado o no es tuyo).", user}

            {:error, reason} ->
              {:error, "❌ Error al cancelar viaje: #{inspect(reason)}", user}
          end
        else
          {:error, "⚠️ El viaje #{trip_id} ya finalizó.", user}
        end
    end
  end

  # cancel_trip -> para conductores (cancelar después de aceptar)
  defp process_remote_command("cancel_trip " <> trip_id, %{role: :driver} = user) do
    trip_id = String.trim(trip_id)

    # Primero verificar si el viaje existe
    case Registry.lookup(UrbanFleet.TripRegistry, trip_id) do
      [] ->
        {:error, "⚠️ El viaje #{trip_id} no existe o ya finalizó.", user}

      [{pid, _}] ->
        if Process.alive?(pid) do
          case UrbanFleet.Trip.cancel_trip(trip_id, user.username) do
            {:ok, _trip} ->
              {:ok, "🛑 Viaje #{trip_id} cancelado. Penalización aplicada: -10 puntos.", user}

            {:error, :cannot_cancel} ->
              {:error, "⚠️ No puedes cancelar este viaje (no estás asignado o no está en progreso).", user}

            {:error, reason} ->
              {:error, "❌ Error al cancelar viaje: #{inspect(reason)}", user}
          end
        else
          {:error, "⚠️ El viaje #{trip_id} ya finalizó.", user}
        end
    end
  end

  # request_trip -> solo para clientes
  defp process_remote_command("request_trip " <> args, %{role: :client} = user) do
    case parse_trip_args(args) do
      {:ok, origin, destination} ->
        case UrbanFleet.Location.validate_locations([origin, destination]) do
          :ok ->
            case UrbanFleet.TripSupervisor.create_trip(user.username, origin, destination) do
              {:ok, trip_id} ->
                msg = """
                ✅ Viaje solicitado!
                ID: #{trip_id}
                Ruta: #{origin} → #{destination}
                Esperando conductor... (expira en 60s)
                """
                {:ok, String.trim(msg), user}

              {:error, :already_has_active_trip} ->
                {:error, "⚠️ Ya tienes un viaje activo. No puedes solicitar otro hasta que termine.", user}

              {:error, reason} ->
                {:error, "❌ No se pudo crear el viaje: #{inspect(reason)}", user}
            end

          {:error, invalid} ->
            {:error, "⚠️ Localizaciones inválidas: #{Enum.join(invalid, ", ")}", user}
        end

      :error ->
        {:error, "✗ Uso: request <origin> <dest>  (o request_trip origen=.. destino=.. )", user}
    end
  end

  # list_trips -> para conductores
  defp process_remote_command("list_trips", %{role: :driver} = user) do
    trips = UrbanFleet.Trip.list_available()

    if Enum.empty?(trips) do
      {:ok, "🚫 No hay viajes disponibles por ahora.", user}
    else
      lines =
        trips
        |> Enum.map(fn trip ->
          "ID: #{trip.id}\nCliente: #{trip.client}\nRuta: #{trip.origin} → #{trip.destination}\nCreado: #{format_datetime(trip.created_at)}\n"
        end)
        |> Enum.join("\n" <> String.duplicate("─", 40) <> "\n")

      {:ok, lines, user}
    end
  end

  # accept_trip -> para conductores
  defp process_remote_command("accept_trip " <> trip_id, %{role: :driver} = user) do
    case UrbanFleet.Trip.accept_trip(String.trim(trip_id), user.username) do
      {:ok, trip} ->
        msg = """
        ✅ Viaje aceptado!
        Cliente: #{trip.client}
        Ruta: #{trip.origin} → #{trip.destination}
        Duración: ~60s
        Ganarás +15 puntos al completarlo.
        """
        {:ok, String.trim(msg), user}

      {:error, :trip_not_available} ->
        {:error, "⚠️ El viaje ya no está disponible.", user}

      {:error, reason} ->
        {:error, "❌ Error al aceptar viaje: #{inspect(reason)}", user}
    end
  end

  # my_score -> cualquier usuario loggeado
  defp process_remote_command("my_score", %{username: uname} = user) do
    case UrbanFleet.UserManager.get_score(uname) do
      {:ok, score} ->
        {:ok, "⭐ Puntuación de #{uname}: #{score} puntos", user}

      _ ->
        {:error, "⚠️ No se pudo obtener la puntuación.", user}
    end
  end

  # ranking (global) y ranking <role>
  defp process_remote_command("ranking", user) do
    ranking = UrbanFleet.UserManager.get_ranking(nil)
    msg = format_ranking(ranking, "🏆 RANKING GLOBAL")
    {:ok, msg, user}
  end

  defp process_remote_command("ranking " <> role, user) when role in ["client", "driver"] do
    role_atom = String.to_atom(role)
    ranking = UrbanFleet.UserManager.get_ranking(role_atom)
    title = if role_atom == :client, do: "👥 RANKING CLIENTES", else: "🚗 RANKING CONDUCTORES"
    msg = format_ranking(ranking, title)
    {:ok, msg, user}
  end

  # disconnect -> cierra la sesión del cliente
  defp process_remote_command("disconnect", %{username: name} = _user) do
    {:ok, "👋 Desconectado. Hasta luego #{name}!", :logout}
  end

  # fallback para comandos remotos desconocidos o no autorizados
  defp process_remote_command(_cmd, nil), do: {:error, "Comando desconocido o no autorizado. Usa 'connect' primero.", nil}
  defp process_remote_command(cmd, user), do: {:error, "Comando desconocido o no autorizado: #{cmd}", user}

  # Ayudante para formatear listas de ranking
  defp format_ranking(list, title) do
    header = "\n#{title}\n" <> String.duplicate("═", 50) <> "\n"
    body =
      list
      |> Enum.with_index(1)
      |> Enum.map(fn {u, idx} -> "#{idx}. #{u.username} (#{u.role}) - #{u.score} puntos" end)
      |> Enum.join("\n")

    header <> body <> "\n"
  end

  # ==============================
  # FUNCIONES AUXILIARES
  # ==============================

  defp show_server_banner do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║        🖥️  MODO SERVIDOR URBANFLEET     ║
    ╚════════════════════════════════════════╝

    Bienvenido Administrador.
    Escribe 'help_admin' para ver los comandos disponibles.
    """)
  end

  defp show_guest_help do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║        👋 BIENVENIDO A URBANFLEET       ║
    ╚════════════════════════════════════════╝
    connect <user> <pass> <client|driver> - Iniciar sesión o registrar
    help                                  - Mostrar este menú
    exit                                  - Salir
    """)
  end

  defp show_client_help do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║           📱 COMANDOS CLIENTE           ║
    ╚════════════════════════════════════════╝
    request <origin> <dest>                 - Solicitar viaje (forma corta)
    request_trip origen=<loc> destino=<loc> - Solicitar viaje (forma larga)
    cancel <trip_id>                        - Cancelar viaje (antes de asignar conductor)
    list_zones (o zones)                    - Ver zonas disponibles
    my_score                                - Ver tu puntuación
    ranking                                 - Ver ranking global
    disconnect                              - Desconectarse
    """)
  end

  defp show_driver_help do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║           🚕 COMANDOS CONDUCTOR         ║
    ╚════════════════════════════════════════╝
    list_trips        - Ver viajes disponibles
    accept_trip <id>  - Aceptar viaje
    cancel <id>       - Cancelar viaje aceptado (penalización -10 pts)
    list_zones        - Ver zonas disponibles
    my_score          - Ver tu puntuación
    ranking driver    - Ver ranking de conductores
    disconnect        - Desconectarse
    """)
  end

  defp show_admin_help do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║          🧠 MODO ADMINISTRADOR          ║
    ╚════════════════════════════════════════╝
    add_zone <nombre>        - Agregar nueva zona
    list_zones               - Mostrar zonas válidas
    show_stats               - Ver estadísticas del sistema
    show_users               - Ver usuarios registrados
    help_admin               - Mostrar este menú
    exit                     - Salir del modo servidor
    """)
  end

  defp parse_trip_args(args) do
    parts = String.split(args)

    if Enum.any?(parts, &String.contains?(&1, "=")) do
      origin =
        Enum.find_value(parts, fn part ->
          case String.split(part, "=") do
            ["origen", loc] -> loc
            _ -> nil
          end
        end)

      destination =
        Enum.find_value(parts, fn part ->
          case String.split(part, "=") do
            ["destino", loc] -> loc
            _ -> nil
          end
        end)

      if origin && destination, do: {:ok, origin, destination}, else: :error
    else
      case parts do
        [origin, dest | _rest] ->
          {:ok, origin, dest}

        [single_dest] when single_dest != "" ->
          origin = "Centro"
          {:ok, origin, single_dest}

        _ ->
          :error
      end
    end
  end

  # ==============================
  # Bucle del CLI local del servidor
  # ==============================
  defp server_cli_loop do
    prompt = IO.ANSI.light_blue_background() <> IO.ANSI.black() <> "[servidor-admin] > " <> IO.ANSI.reset()
    input = IO.gets(prompt)

    case input do
      nil ->
        IO.puts("\n👋 Cerrando CLI del servidor...")

      raw ->
        cmd = String.trim(raw)
        case process_server_command(cmd) do
          :continue -> server_cli_loop()
          :exit -> IO.puts("🖥️ Servidor detenido (CLI finalizado).")
        end
    end
  end

  defp process_server_command("help") do
    IO.puts("""
    ╔════════════════════════════════════════╗
    ║        🧠 MODO ADMINISTRADOR DEL SERVIDOR     ║
    ╚════════════════════════════════════════╝
    Comandos disponibles:
      add_zone <nombre>   - Agregar una nueva zona
      list_zones          - Listar zonas actuales
      show_stats          - Ver estadísticas del sistema
      show_users          - Ver usuarios registrados
      clear_screen        - Limpiar pantalla
      exit                - Cerrar CLI del servidor
    """)
    :continue
  end

  defp process_server_command("add_zone " <> zone) do
    UrbanFleet.Location.add_location(String.trim(zone))
    IO.puts("✅ Zona '#{zone}' agregada correctamente.")
    :continue
  end

  defp process_server_command("list_zones") do
    if function_exported?(UrbanFleet, :show_locations, 0) do
      UrbanFleet.show_locations()
    else
      IO.puts("⚠️ Comando 'list_zones' no disponible.")
    end
    :continue
  end

  defp process_server_command("show_stats") do
    if function_exported?(UrbanFleet, :show_stats, 0) do
      UrbanFleet.show_stats()
    else
      IO.puts("⚠️ Comando 'show_stats' no disponible.")
    end
    :continue
  end

  defp process_server_command("show_users") do
    IO.puts("\n📋 Usuarios registrados:\n")
    users = :sys.get_state(UrbanFleet.UserManager)
    users
    |> Map.values()
    |> Enum.each(fn u ->
      IO.puts("• #{u.username} (#{u.role}) - #{u.score} puntos")
    end)
    :continue
  end

  defp process_server_command("clear_screen") do
    IO.write(IO.ANSI.clear())
    :continue
  end

  defp process_server_command("exit"), do: :exit
  defp process_server_command(""), do: :continue

  defp process_server_command(cmd) do
    IO.puts("❓ Comando desconocido: #{cmd}. Escribe 'help' para ver los comandos.")
    :continue
  end

  defp notify_user_by_name(username, message, state) when is_binary(username) do
    case Map.get(state.sessions, username) do
      nil ->
        Logger.debug("No se encontró sesión para el usuario: #{username}")
        :no_session

      node when is_atom(node) ->
        Logger.debug("Enviando notificación a #{username} en el nodo #{inspect(node)}")
        result = :rpc.call(node, UrbanFleet.Client, :notify, [message])
        Logger.debug("Resultado de la notificación: #{inspect(result)}")
        :ok

      pid when is_pid(pid) ->
        send(pid, {:notify, message})
        :ok

      other ->
        Logger.warn("Tipo de sesión desconocido para #{username}: #{inspect(other)}")
        :no_session
    end
  end
end
