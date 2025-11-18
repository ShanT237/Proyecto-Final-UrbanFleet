defmodule UrbanFleet.TripSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # API del cliente

  @doc """
  Crea un nuevo proceso de viaje bajo supervisión.
  Retorna {:ok, trip_id} o {:error, reason}
  """
  def create_trip(client_username, origin, destination) do
    # Verificar si el cliente ya tiene un viaje activo
    if client_has_active_trip?(client_username) do
      {:error, :already_has_active_trip}
    else
      trip_id = generate_trip_id()

      trip_data = %{
        id: trip_id,
        client: client_username,
        origin: origin,
        destination: destination
      }

      case DynamicSupervisor.start_child(__MODULE__, {UrbanFleet.Trip, trip_data}) do
        {:ok, _pid} ->
          Logger.info("Viaje #{trip_id} creado exitosamente")
          {:ok, trip_id}

        {:error, reason} ->
          Logger.error("No se pudo crear el viaje: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Lista todos los viajes activos con manejo de errores robusto.
  """
  def list_all_trips do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} ->
      try do
        if Process.alive?(pid) do
          case GenServer.call(pid, :get_state, 1000) do
            state when is_map(state) -> state
            _ -> nil
          end
        else
          nil
        end
      catch
        :exit, _ -> nil
      rescue
        _ -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  @doc """
  Cuenta los viajes activos.
  """
  def count_trips do
    DynamicSupervisor.count_children(__MODULE__)
  end

  @doc """
  Verifica si un cliente tiene un viaje activo de forma segura.
  """
  defp client_has_active_trip?(client_username) do
    # Usar Registry directamente para evitar race conditions
    trip_ids = Registry.select(UrbanFleet.TripRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])

    Enum.any?(trip_ids, fn trip_id ->
      case UrbanFleet.Trip.get_state(trip_id) do
        {:error, _} ->
          false
        state when is_map(state) ->
          state.client == client_username and state.status in [:available, :in_progress]
        _ ->
          false
      end
    end)
  end

  defp generate_trip_id do
    # ID corto tipo "T12345" (más legible que timestamps largos)
    n = :erlang.unique_integer([:positive])
    short = rem(n, 100_000)
    "T#{short}"
  end
end
