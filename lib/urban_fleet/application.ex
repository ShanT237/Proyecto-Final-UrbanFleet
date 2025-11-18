defmodule UrbanFleet.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Registro de viajes
      {Registry, keys: :unique, name: UrbanFleet.TripRegistry},

      # Gestor de usuarios (autenticación y puntuación)
      UrbanFleet.UserManager,

      # Supervisor de viajes
      UrbanFleet.TripSupervisor,

      # Servidor principal (manejador de la CLI)
      UrbanFleet.Server
    ]

    opts = [strategy: :one_for_one, name: UrbanFleet.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("La aplicación UrbanFleet se inició correctamente")

        Process.sleep(100)
        UrbanFleet.Server.start_cli()

        {:ok, pid}

      error ->
        Logger.error("No se pudo iniciar la aplicación UrbanFleet: #{inspect(error)}")
        error
    end
  end
end
