defmodule UrbanFleet.UserManager do
  use GenServer
  require Logger

  @users_file "data/users.dat"

  # API del cliente (funciones públicas)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register_or_login(username, password, role) do
    GenServer.call(__MODULE__, {:register_or_login, username, password, role})
  end

  def get_user(username) do
    GenServer.call(__MODULE__, {:get_user, username})
  end

  def get_score(username) do
    GenServer.call(__MODULE__, {:get_score, username})
  end

  def get_ranking(role \\ nil) do
    GenServer.call(__MODULE__, {:get_ranking, role})
  end

  def trip_completed(client_username, driver_username, trip_id) do
    GenServer.cast(__MODULE__, {:trip_completed, client_username, driver_username, trip_id})
  end

  def trip_expired(client_username, trip_id) do
    GenServer.cast(__MODULE__, {:trip_expired, client_username, trip_id})
  end

  def trip_cancelled(driver_username, trip_id) do
    GenServer.cast(__MODULE__, {:driver_cancelled, driver_username, trip_id})
  end

  # Callbacks del servidor

  @impl true
  def init(_) do
    users = load_users()
    Logger.info("UserManager inicializado con #{map_size(users)} usuarios")
    {:ok, users}
  end

  @impl true
  def handle_call({:register_or_login, username, password, role}, _from, users) do
    case Map.get(users, username) do
      nil ->
        # Registrar nuevo usuario
        new_user = %{
          username: username,
          password: hash_password(password),
          role: role,
          score: 0
        }

        new_users = Map.put(users, username, new_user)
        save_users(new_users)

        Logger.info("Nuevo usuario registrado: #{username} (#{role})")

        {:reply, {:ok, :registered, new_user}, new_users}

      user ->
        # Iniciar sesión de un usuario existente
        if verify_password(password, user.password) do
          Logger.info("Usuario inició sesión: #{username}")
          {:reply, {:ok, :logged_in, user}, users}
        else
          {:reply, {:error, :invalid_password}, users}
        end
    end
  end

  @impl true
  def handle_call({:get_user, username}, _from, users) do
    user = Map.get(users, username)
    {:reply, user, users}
  end

  @impl true
  def handle_call({:get_score, username}, _from, users) do
    score =
      case Map.get(users, username) do
        nil -> {:error, :user_not_found}
        user -> {:ok, user.score}
      end

    {:reply, score, users}
  end

  @impl true
  def handle_call({:get_ranking, role}, _from, users) do
    ranking =
      users
      |> Map.values()
      |> Enum.filter(fn user ->
        is_nil(role) || user.role == role
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(10)

    {:reply, ranking, users}
  end

  @impl true
  def handle_cast({:trip_completed, client_username, driver_username, trip_id}, users) do
    Logger.info("Viaje #{trip_id} completado - asignando puntos")

    new_users =
      users
      |> update_score(client_username, 10)
      |> update_score(driver_username, 15)

    save_users(new_users)
    {:noreply, new_users}
  end

  @impl true
  def handle_cast({:trip_expired, client_username, trip_id}, users) do
    # Antes se penalizaba al cliente por expiración; ahora ya no según los requisitos actuales
    Logger.warn("El viaje #{trip_id} expiró – sin penalización para el cliente (política actualizada)")
    {:noreply, users}
  end

  @impl true
  def handle_cast({:driver_cancelled, driver_username, trip_id}, users) do
    Logger.warn("Viaje #{trip_id} cancelado por el conductor #{driver_username} – penalizando conductor")

    new_users = update_score(users, driver_username, -10)
    save_users(new_users)

    {:noreply, new_users}
  end

  # Funciones auxiliares privadas

  defp update_score(users, username, points) do
    case Map.get(users, username) do
      nil ->
        Logger.warn("Intento de actualizar puntaje de usuario desconocido #{username}. Ignorado.")
        users

      user ->
        Map.put(users, username, %{user | score: user.score + points})
    end
  end

  defp hash_password(password) do
    # Hash simple – en producción usar Argon2 u otro algoritmo seguro
    :crypto.hash(:sha256, password) |> Base.encode64()
  end

  defp verify_password(password, hashed) do
    hash_password(password) == hashed
  end

  defp load_users do
    case File.read(@users_file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_user_line/1)
        |> Enum.filter(&(&1 != nil))
        |> Map.new(fn user -> {user.username, user} end)

      {:error, :enoent} ->
        Logger.info("No existe archivo de usuarios; iniciando desde cero")
        %{}

      {:error, reason} ->
        Logger.error("No se pudieron cargar los usuarios: #{inspect(reason)}")
        %{}
    end
  end

  defp parse_user_line(line) do
    case String.split(line, "|") do
      [username, role, password, score] ->
        %{
          username: username,
          role: String.to_atom(role),
          password: password,
          score: String.to_integer(score)
        }

      _ ->
        nil
    end
  end

  defp save_users(users) do
    content =
      users
      |> Map.values()
      |> Enum.map(fn user ->
        "#{user.username}|#{user.role}|#{user.password}|#{user.score}"
      end)
      |> Enum.join("\n")

    File.mkdir_p!("data")
    File.write!(@users_file, content <> "\n")
  end
end
