#!/usr/bin/env elixir

IO.puts("🚖 Iniciando SERVIDOR UrbanFleet...\n")

# =======================================
# CARGA DE MÓDULOS (EN ORDEN CORRECTO)
# =======================================
Code.compile_file("lib/urban_fleet/location.ex")
Code.compile_file("lib/urban_fleet/persistence.ex")
Code.compile_file("lib/urban_fleet/user_manager.ex")
Code.compile_file("lib/urban_fleet/trip.ex")
Code.compile_file("lib/urban_fleet/trip_supervisor.ex")
Code.compile_file("lib/urban_fleet.ex")      # 👈 Primero el módulo principal
Code.compile_file("lib/urban_fleet/server.ex")

# =======================================
# DATOS INICIALES
# =======================================
File.mkdir_p!("data")

unless File.exists?("data/locations.dat") do
  File.write!("data/locations.dat", """
  Parque
  Centro
  Aeropuerto
  Universidad
  Hospital
  Plaza
  Estadio
  Biblioteca
  Mercado
  Terminal
  """)
end

# =======================================
# INICIALIZACIÓN DE PROCESOS
# =======================================
{:ok, _registry} = Registry.start_link(keys: :unique, name: UrbanFleet.TripRegistry)
{:ok, _user_manager} = UrbanFleet.UserManager.start_link([])
{:ok, _trip_supervisor} = UrbanFleet.TripSupervisor.start_link([])
{:ok, _server} = UrbanFleet.Server.start_link([])

# =======================================
# BANNER DEL SERVIDOR
# =======================================

IO.puts("Estado del sistema: ✓ En ejecución\n")
IO.puts("Esperando que clientes/conductores se conecten...\n")

# =======================================
# LANZAR CLI DIRECTAMENTE
# =======================================
# 👇 Esto invoca la interfaz interactiva directamente (sin GenServer.cast)
spawn(fn -> UrbanFleet.Server.start_cli() end)

# =======================================
# MANTENER VIVO EL SERVIDOR
# =======================================
Process.sleep(:infinity)
