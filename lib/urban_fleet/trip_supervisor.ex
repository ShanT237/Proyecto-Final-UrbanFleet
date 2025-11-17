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

  # Client API

  @doc """
  Crea un nuevo proceso de viaje bajo supervición.
  Returns {:ok, trip_id} or {:error, reason}
  """
  def create_trip(client_username, origin, destination) do
    # Check if client already has an active trip
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
          Logger.info("Trip #{trip_id} created successfully")
          {:ok, trip_id}

        {:error, reason} ->
          Logger.error("Failed to create trip: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Lista todos los viajes activos
  """
  def list_all_trips do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} ->
      try do
        if Process.alive?(pid) do
          GenServer.call(pid, :get_state)
        else
          nil
        end
      rescue
        _ -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  @doc """
  Cuenta los viajes activos
  """
  def count_trips do
    DynamicSupervisor.count_children(__MODULE__)
  end

  defp client_has_active_trip?(client_username) do
    list_all_trips()
    |> Enum.any?(fn trip ->
      trip.client == client_username and trip.status in [:available, :in_progress]
    end)
  end

  defp generate_trip_id do
    # ID corto tipo "T12345" (más legible que timestamps largos)
    n = :erlang.unique_integer([:positive])
    short = rem(n, 100_000)
    "T#{short}"
  end
end
