defmodule UrbanFleet do
  @moduledoc """
  UrbanFleet - Sistema de simulación de una flota de taxis multijugador.

  Este sistema simula un servicio de despacho de taxis en tiempo real donde:
  - Clientes pueden solicitar viajes
  - Conductores pueden aceptar y completar viajes
  - Se otorgan puntos por viajes exitosos
  - Todas las operaciones corren concurrentemente usando OTP

  ## Uso

  Iniciar la aplicación:
  ```
  iex -S mix
  ```

  La interfaz CLI se inicia automáticamente. Comandos disponibles:

  ### Conexión
  - `connect <username> <password> <client|driver>` - Registrar o iniciar sesión
  - `disconnect` - Desconectarse del sistema

  ### Comandos para clientes
  - `request_trip origen=<location> destino=<location>` - Solicitar un viaje
  - `my_score` - Ver tu puntuación

  ### Comandos para conductores
  - `list_trips` - Listar viajes disponibles
  - `accept_trip <trip_id>` - Aceptar un viaje
  - `my_score` - Ver tu puntuación

  ### Comandos generales
  - `ranking [client|driver]` - Ver rankings
  - `help` - Mostrar ayuda
  - `exit` - Salir de la aplicación

  ## Sistema de puntuación
  - Cliente completa viaje: +10 puntos
  - Conductor completa viaje: +15 puntos
  - Viaje expira sin conductor: Cliente pierde -5 puntos

  ## Arquitectura

  El sistema utiliza:
  - GenServers para procesos con estado (viajes, usuarios)
  - DynamicSupervisor para gestionar procesos de viaje
  - Registry para localizar procesos de viaje
  - Persistencia en archivos para usuarios y resultados
  """

  @doc """
  Returns the application version
  """
  def version do
    Application.spec(:urban_fleet, :vsn) |> to_string()
  end

  @doc """
  Muestra información de la aplicación
  """
  def info do
    IO.puts("""

    ╔════════════════════════════════════════╗
    ║         URBANFLEET v#{version()}           ║
    ║    Sistema Multijugador de Flota de Taxis      ║
    ╚════════════════════════════════════════╝

    Estado: #{if running?(), do: "En ejecución ✓", else: "Detenido ✗"}

    Escribe 'help' para ver los comandos disponibles.
    """)
  end

  @doc """
  Checks if the application is running
  """
  def running? do
    Process.whereis(UrbanFleet.Server) != nil
  end

  @doc """
  Gets current system statistics
  """
  def stats do
    trip_stats = UrbanFleet.TripSupervisor.count_trips()
    persistence_stats = UrbanFleet.Persistence.get_statistics()

    %{
      active_trips: trip_stats.active,
      total_trips_completed: persistence_stats.total,
      completion_rate: persistence_stats.completion_rate,
      trips_expired: persistence_stats.expired
    }
  end

  @doc """
  Displays current system statistics
  """
  def show_stats do
    stats = stats()

    IO.puts("""

    System Statistics
    ═════════════════
    Active Trips: #{stats.active_trips}
    Total Completed: #{stats.total_trips_completed}
    Completion Rate: #{stats.completion_rate}%
    Expired: #{stats.trips_expired}
    """)
  end

  @doc """
  Lists all valid locations
  """
  def locations do
    UrbanFleet.Location.list_locations()
  end

  @doc """
  Displays all valid locations
  """
  def show_locations do
    locations = locations()

    IO.puts("\nValid Locations:")
    IO.puts("═══════════════")
    Enum.each(locations, fn loc ->
      IO.puts("  • #{loc}")
    end)
    IO.puts("")
  end
end
