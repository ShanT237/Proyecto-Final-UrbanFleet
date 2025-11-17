defmodule UrbanFleet.Trip do
  use GenServer
  require Logger

  @trip_duration 60_000 # 60 seconds in milliseconds
  @tick_interval 1_000  # 1 second ticks for countdown

  # Ensure dynamic children are temporary (don't restart after normal exit)
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      type: :worker
    }
  end

  # Client API

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
    GenServer.call(via_tuple(trip_id), {:cancel_trip, driver_username})
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

  # Server Callbacks

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

    # Schedule expiration check and first tick
    Process.send_after(self(), :check_expiration, @trip_duration)
    Process.send_after(self(), :tick, @tick_interval)

    Logger.info("Trip #{state.id} created: #{state.origin} -> #{state.destination}")

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

    # Schedule completion after trip duration (from accept)
    Process.send_after(self(), :complete_trip, @trip_duration)
    # Continue ticks (tick loop already scheduled)

    Logger.info("Trip #{state.id} accepted by driver #{driver_username}")

    {:reply, {:ok, new_state}, new_state}
  end

  @impl true
  def handle_call({:accept_trip, _driver_username}, _from, state) do
    {:reply, {:error, :trip_not_available}, state}
  end

  # Cancelling by driver
  @impl true
  def handle_call({:cancel_trip, driver_username}, _from, %{status: :in_progress, driver: driver_username} = state) do
    new_state = %{state |
      status: :cancelled,
      completed_at: DateTime.utc_now()
    }

    # Penalize driver (use UserManager helper)
    UrbanFleet.UserManager.trip_cancelled(driver_username, state.id)

    # Log and notify
    UrbanFleet.Persistence.log_trip_result(new_state)
    if Process.whereis(:server), do: send(:server, {:trip_cancelled, new_state})

    {:reply, {:ok, new_state}, new_state}
  end

  @impl true
  def handle_call({:cancel_trip, _driver_username}, _from, state) do
    {:reply, {:error, :cannot_cancel}, state}
  end

  # Ticks: send remaining time updates to server (every second)
  @impl true
  def handle_info(:tick, state) do
    remaining_ms = DateTime.diff(state.end_time, DateTime.utc_now(), :millisecond)
    remaining_ms = if remaining_ms < 0, do: 0, else: remaining_ms

    if Process.whereis(:server) do
      send(:server, {:trip_tick, state.id, remaining_ms})
    end

    # continue ticking while not finished
    cond do
      remaining_ms > 0 ->
        Process.send_after(self(), :tick, @tick_interval)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:check_expiration, %{status: :available} = state) do
    # Trip expired without driver - no client penalty per request
    Logger.warn("Trip #{state.id} expired without driver")

    new_state = %{state |
      status: :expired,
      completed_at: DateTime.utc_now()
    }

    # Log result
    UrbanFleet.Persistence.log_trip_result(new_state)

    # Notify server (so admin/CLI sees it)
    if Process.whereis(:server), do: send(:server, {:trip_expired, new_state})

    # Stop the GenServer after logging
    {:stop, :normal, new_state}
  end

  @impl true
  def handle_info(:check_expiration, state) do
    # Trip was accepted or already handled
    {:noreply, state}
  end

  @impl true
  def handle_info(:complete_trip, %{status: :in_progress} = state) do
    Logger.info("Trip #{state.id} completed successfully")

    new_state = %{state |
      status: :completed,
      completed_at: DateTime.utc_now()
    }

    # Award points to both client and driver
    UrbanFleet.UserManager.trip_completed(state.client, state.driver, state.id)

    # Log result
    UrbanFleet.Persistence.log_trip_result(new_state)

    # Notify server (so admin/CLI sees it)
    if Process.whereis(:server), do: send(:server, {:trip_completed, new_state})

    # Stop the GenServer after completion
    {:stop, :normal, new_state}
  end

  @impl true
  def handle_info(:complete_trip, state) do
    # Trip was cancelled or already completed
    {:noreply, state}
  end

  # Helper Functions

  defp via_tuple(trip_id) do
    {:via, Registry, {UrbanFleet.TripRegistry, trip_id}}
  end
end
