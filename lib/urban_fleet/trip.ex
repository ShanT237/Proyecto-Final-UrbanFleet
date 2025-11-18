defmodule UrbanFleet.Trip do
  use GenServer
  require Logger

  @trip_duration 60_000 # 60 segundos en milisegundos
  @tick_interval 1_000  # ticks de 1 segundo para la cuenta regresiva

  # Asegurar que los hijos dinámicos sean temporales (no reiniciar después de una salida normal)
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      type: :worker
    }
  end

  # API del Cliente

  def start_link(trip_data) do
    GenServer.start_link(__MODULE__, trip_data, name: via_tuple(trip_data.id))
  end

  def get_state(trip_id) do
    GenServer.call(via_tuple(trip_id), :get_state)
  end

  def accept_trip(trip_id, driver_username) do
    GenServer.call(via_tuple(trip_id), {:accept_trip, driver_username})
  end

  def cancel_trip(trip_id, driver_username) do
    GenServer.call(via_tuple(trip_id), {:cancel_trip_by_driver, driver_username})
  end

  def cancel_trip_by_client(trip_id, client_username) do
    GenServer.call(via_tuple(trip_id), {:cancel_trip_by_client, client_username})
  end

  def list_available do
    # Obtener todos los trip_ids registrados en el Registry
    trip_ids = Registry.select(UrbanFleet.TripRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])

    trip_ids
    |> Enum.map(fn trip_id ->
      try do
        get_state(trip_id)
      rescue
        _ -> nil
      end
    end)
    |> Enum.filter(fn
      %{status: :available} -> true
      _ -> false
    end)
  end

  # Callbacks del Servidor

  @impl true
  def init(trip_data) do
    now = DateTime.utc_now()
    end_time = DateTime.add(now, div(@trip_duration, 1000), :second)

    state = Map.merge(trip_data, %{
      status: :available,
      driver: nil,
      created_at: now,
      started_at: nil,
      completed_at: nil,
      end_time: end_time
    })

    # Programar solo la comprobación de expiración (sin ticks)
    Process.send_after(self(), :check_expiration, @trip_duration)

    Logger.info("Viaje #{state.id} creado: #{state.origin} -> #{state.destination}")

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:accept_trip, driver_username}, _from, %{status: :available} = state) do
    now = DateTime.utc_now()
    end_time = DateTime.add(now, div(@trip_duration, 1000), :second)

    new_state = %{state |
      status: :in_progress,
      driver: driver_username,
      started_at: now,
      end_time: end_time
    }

    # Programar finalización después de la duración del viaje (desde la aceptación)
    Process.send_after(self(), :complete_trip, @trip_duration)

    Logger.info("Viaje #{state.id} aceptado por el conductor #{driver_username}")

    {:reply, {:ok, new_state}, new_state}
  end

  @impl true
  def handle_call({:accept_trip, _driver_username}, _from, state) do
    {:reply, {:error, :trip_not_available}, state}
  end

  # Cancelación por conductor (viaje en progreso)
  @impl true
  def handle_call({:cancel_trip_by_driver, driver_username}, _from, %{status: :in_progress, driver: driver_username} = state) do
    new_state = %{state |
      status: :cancelled,
      completed_at: DateTime.utc_now()
    }

    # Penalizar al conductor (usar helper de UserManager)
    UrbanFleet.UserManager.trip_cancelled(driver_username, state.id)

    # Registrar y notificar
    UrbanFleet.Persistence.log_trip_result(new_state)

    # Enviar notificación al servidor
    if Process.whereis(:server) do
      send(:server, {:trip_cancelled, new_state})
    end

    Logger.info("Viaje #{state.id} cancelado por el conductor #{driver_username}")

    # Detener el GenServer después de cancelar
    {:stop, :normal, {:ok, new_state}, new_state}
  end

  @impl true
  def handle_call({:cancel_trip_by_driver, _driver_username}, _from, state) do
    {:reply, {:error, :cannot_cancel}, state}
  end

  # Cancelación por cliente (viaje disponible, sin conductor asignado)
  @impl true
  def handle_call({:cancel_trip_by_client, client_username}, _from, %{status: :available, client: client_username} = state) do
    new_state = %{state |
      status: :cancelled,
      completed_at: DateTime.utc_now()
    }

    # Registrar la cancelación
    UrbanFleet.Persistence.log_trip_result(new_state)

    Logger.info("Viaje #{state.id} cancelado por el cliente #{client_username}")

    # Detener el GenServer después de cancelar
    {:stop, :normal, {:ok, new_state}, new_state}
  end

  @impl true
  def handle_call({:cancel_trip_by_client, _client_username}, _from, state) do
    {:reply, {:error, :cannot_cancel}, state}
  end

  # Ticks: ya no envían actualizaciones, solo esperamos la finalización
  @impl true
  def handle_info(:tick, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_expiration, %{status: :available} = state) do
    # El viaje expiró sin conductor
    Logger.warn("El viaje #{state.id} expiró sin conductor")

    new_state = %{state |
      status: :expired,
      completed_at: DateTime.utc_now()
    }

    # Registrar resultado
    UrbanFleet.Persistence.log_trip_result(new_state)

    # Notificar al servidor (para que admin/CLI y clientes lo vean)
    if Process.whereis(:server) do
      send(:server, {:trip_expired, new_state})
    end

    # Detener el GenServer después de registrarlo
    {:stop, :normal, new_state}
  end

  @impl true
  def handle_info(:check_expiration, state) do
    # El viaje ya fue aceptado o ya fue manejado
    {:noreply, state}
  end

  @impl true
  def handle_info(:complete_trip, %{status: :in_progress} = state) do
    Logger.info("Viaje #{state.id} completado exitosamente")

    new_state = %{state |
      status: :completed,
      completed_at: DateTime.utc_now()
    }

    # Dar puntos a cliente y conductor
    UrbanFleet.UserManager.trip_completed(state.client, state.driver, state.id)

    # Registrar resultado
    UrbanFleet.Persistence.log_trip_result(new_state)

    # Notificar al servidor
    if Process.whereis(:server) do
      send(:server, {:trip_completed, new_state})
    end

    # Detener GenServer después de la finalización
    {:stop, :normal, new_state}
  end

  @impl true
  def handle_info(:complete_trip, state) do
    # El viaje fue cancelado o ya estaba completado
    {:noreply, state}
  end

  # Funciones Helper

  defp via_tuple(trip_id) do
    {:via, Registry, {UrbanFleet.TripRegistry, trip_id}}
  end
end
