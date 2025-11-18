defmodule UrbanFleet.Persistence do
  @moduledoc """
  Módulo de persistencia para resultados de viajes.
  """

  @results_file "data/results.log"

  @doc """
  Registra el resultado de un viaje en el archivo results.log
  Formato: fecha; cliente=<name>; conductor=<name>; origen=<loc>; destino=<loc>; status=<status>
  """
  def log_trip_result(trip) do
    timestamp = format_datetime(trip.completed_at || DateTime.utc_now())

    driver = trip.driver || "ninguno"
    status = format_status(trip.status)

    line = "#{timestamp}; cliente=#{trip.client}; conductor=#{driver}; " <>
           "origen=#{trip.origin}; destino=#{trip.destination}; status=#{status}\n"

    File.mkdir_p!("data")
    File.write!(@results_file, line, [:append])
  end

  @doc """
  Lee los resultados de los viajes desde results.log
  """
  def read_results do
    case File.read(@results_file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_result_line/1)
        |> Enum.filter(&(&1 != nil))

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Obtiene las estadististicas
  """
  def get_statistics do
    results = read_results()

    total = length(results)
    completed = Enum.count(results, &(&1.status == "Completado"))
    expired = Enum.count(results, &(&1.status == "Expirado"))

    %{
      total: total,
      completed: completed,
      expired: expired,
      completion_rate: if(total > 0, do: Float.round(completed / total * 100, 2), else: 0.0)
    }
  end


  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  defp format_status(:completed), do: "Completado"
  defp format_status(:expired), do: "Expirado"
  defp format_status(:cancelled), do: "Cancelado"
  defp format_status(_), do: "Desconocido"

  defp parse_result_line(line) do
    parts = String.split(line, ";")
    |> Enum.map(&String.trim/1)

    case parts do
      [timestamp | rest] ->
        data = rest
        |> Enum.map(fn part ->
          case String.split(part, "=", parts: 2) do
            [key, value] -> {String.trim(key), String.trim(value)}
            _ -> nil
          end
        end)
        |> Enum.filter(&(&1 != nil))
        |> Map.new()

        Map.put(data, "timestamp", timestamp)

      _ -> nil
    end
  end
end
