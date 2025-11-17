defmodule UrbanFleet.UserManager do
  use GenServer
  require Logger

  @users_file "data/users.dat"

  # Client API

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

  # Server Callbacks

  @impl true
  def init(_) do
    users = load_users()
    Logger.info("UserManager initialized with #{map_size(users)} users")
    {:ok, users}
  end

  @impl true
  def handle_call({:register_or_login, username, password, role}, _from, users) do
    case Map.get(users, username) do
      nil ->
        # Register new user
        new_user = %{
          username: username,
          password: hash_password(password),
          role: role,
          score: 0
        }
        new_users = Map.put(users, username, new_user)
        save_users(new_users)
        Logger.info("New user registered: #{username} (#{role})")
        {:reply, {:ok, :registered, new_user}, new_users}

      user ->
        # Login existing user
        if verify_password(password, user.password) do
          Logger.info("User logged in: #{username}")
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
    score = case Map.get(users, username) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user.score}
    end
    {:reply, score, users}
  end

  @impl true
  def handle_call({:get_ranking, role}, _from, users) do
    ranking = users
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
    Logger.info("Trip #{trip_id} completed - awarding points")

    new_users = users
    |> update_score(client_username, 10)
    |> update_score(driver_username, 15)

    save_users(new_users)
    {:noreply, new_users}
  end

  @impl true
  def handle_cast({:trip_expired, client_username, trip_id}, users) do
    # Previously penalized client on expiration; now we do not penalize per latest requirements
    Logger.warn("Trip #{trip_id} expired - no penalty for client (policy changed)")
    {:noreply, users}
  end

  @impl true
  def handle_cast({:driver_cancelled, driver_username, trip_id}, users) do
    Logger.warn("Trip #{trip_id} cancelled by driver #{driver_username} - penalizing driver")
    new_users = update_score(users, driver_username, -10)
    save_users(new_users)
    {:noreply, new_users}
  end

  # Private Helper Functions

  defp update_score(users, username, points) do
    case Map.get(users, username) do
      nil ->
        Logger.warn("Attempted to update score for unknown user #{username}. Ignoring.")
        users

      user ->
        Map.put(users, username, %{user | score: user.score + points})
    end
  end

  defp hash_password(password) do
    # Simple hash - in production use proper hashing like Argon2
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
        Logger.info("No existing users file, starting fresh")
        %{}

      {:error, reason} ->
        Logger.error("Failed to load users: #{inspect(reason)}")
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
      _ -> nil
    end
  end

  defp save_users(users) do
    content = users
    |> Map.values()
    |> Enum.map(fn user ->
      "#{user.username}|#{user.role}|#{user.password}|#{user.score}"
    end)
    |> Enum.join("\n")

    File.mkdir_p!("data")
    File.write!(@users_file, content <> "\n")
  end
end
