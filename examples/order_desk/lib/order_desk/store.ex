defmodule OrderDesk.Store do
  @moduledoc "SQLite order records and immutable, expiring delivery proposals for the demo customer."
  use GenServer
  alias Exqlite.Sqlite3, as: SQL

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def orders(server \\ __MODULE__), do: GenServer.call(server, :orders)
  def order(id, server \\ __MODULE__), do: GenServer.call(server, {:order, id})
  def dashboard(actor, server \\ __MODULE__), do: GenServer.call(server, {:dashboard, actor})

  def propose(actor, order, text, id, server \\ __MODULE__),
    do: GenServer.call(server, {:propose, actor, order, text, id})

  def confirm(actor, id, server \\ __MODULE__), do: GenServer.call(server, {:confirm, actor, id})
  def reject(actor, id, server \\ __MODULE__), do: GenServer.call(server, {:reject, actor, id})

  def refuse(actor, order, id, server \\ __MODULE__),
    do: GenServer.call(server, {:refuse, actor, order, id})

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    if path != ":memory:", do: File.mkdir_p!(Path.dirname(path))
    {:ok, db} = SQL.open(path)
    if path != ":memory:", do: File.chmod!(path, 0o600)

    :ok =
      SQL.execute(db, """
      PRAGMA journal_mode=WAL;
      PRAGMA synchronous=FULL;
      PRAGMA busy_timeout=1000;
      CREATE TABLE IF NOT EXISTS orders (
        id TEXT PRIMARY KEY, customer TEXT NOT NULL, status TEXT NOT NULL,
        tracking TEXT NOT NULL, items TEXT NOT NULL, instructions TEXT NOT NULL, version INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS proposals (
        id TEXT PRIMARY KEY, actor TEXT NOT NULL, order_id TEXT NOT NULL,
        instructions TEXT NOT NULL, expected_version INTEGER NOT NULL,
        status TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS changes (
        proposal_id TEXT PRIMARY KEY, order_id TEXT NOT NULL, instructions TEXT NOT NULL,
        version INTEGER NOT NULL, changed_at INTEGER NOT NULL);
      """)

    for {id, status, tracking, items} <- [
          {"123", "shipped; expected Friday", "DEMO-123",
           [%{name: "Travel mug", quantity: 1}, %{name: "Coffee beans", quantity: 2}]},
          {"124", "out for delivery", "DEMO-124", [%{name: "Desk lamp", quantity: 1}]},
          {"825", "processing", "Not assigned", [%{name: "Notebook", quantity: 3}]}
        ] do
      query(db, "INSERT OR IGNORE INTO orders VALUES (?, 'demo', ?, ?, ?, '', 1)", [
        id,
        status,
        tracking,
        Jason.encode!(items)
      ])
    end

    {:ok, db}
  end

  @impl true
  def handle_call(:orders, _from, db), do: {:reply, all_orders(db), db}
  def handle_call({:order, id}, _from, db), do: {:reply, get_order(db, id), db}

  def handle_call({:dashboard, actor}, _from, db) do
    proposals =
      query(
        db,
        "SELECT id,order_id,instructions,expected_version,status,expires_at FROM proposals WHERE actor=? ORDER BY created_at DESC,rowid DESC LIMIT 20",
        [actor]
      )
      |> Enum.map(fn [id, order, text, version, status, expiry] ->
        %{
          id: id,
          order: order,
          instructions: text,
          version: version,
          status: if(status == "pending" and expiry <= now(), do: "expired", else: status)
        }
      end)

    changes =
      query(
        db,
        "SELECT proposal_id,order_id,instructions,version,changed_at FROM changes ORDER BY changed_at DESC,rowid DESC LIMIT 20",
        []
      )
      |> Enum.map(fn [id, order, text, version, at] ->
        %{id: id, order: order, instructions: text, version: version, at: at}
      end)

    {:reply, %{orders: all_orders(db), proposals: proposals, changes: changes}, db}
  end

  def handle_call({:propose, actor, order, text, id}, _from, db) do
    result =
      with true <- valid_id?(actor) and valid_id?(id),
           true <- is_binary(text) and String.trim(text) != "" and byte_size(text) <= 300,
           {:ok, record} <- get_order(db, order) do
        case query(db, "SELECT actor,order_id,instructions,status FROM proposals WHERE id=?", [id]) do
          [[^actor, ^order, _text, "rejected"]] ->
            {:error, :rejected}

          [[^actor, ^order, ^text, _status]] ->
            {:ok, %{proposal: id}}

          [] ->
            # An older proposal is never silently edited into a different operation.
            query(db, "INSERT INTO proposals VALUES (?,?,?,?,?,'pending',?,?)", [
              id,
              actor,
              order,
              text,
              record.version,
              now(),
              now() + 300
            ])

            {:ok, %{proposal: id}}

          _conflict ->
            {:error, :conflict}
        end
      else
        false -> {:error, :invalid_argument}
        error -> error
      end

    {:reply, result, db}
  end

  def handle_call({:confirm, actor, id}, _from, db) do
    :ok = SQL.execute(db, "BEGIN IMMEDIATE")
    result = confirm_transaction(db, actor, id)
    :ok = SQL.execute(db, "COMMIT")
    {:reply, result, db}
  end

  def handle_call({:reject, actor, id}, _from, db) do
    query(
      db,
      "UPDATE proposals SET status='rejected' WHERE id=? AND actor=? AND status='pending'",
      [id, actor]
    )

    {:reply, :ok, db}
  end

  # Serialized with propose/confirm. A refusal may arrive before the delayed
  # creation job; a tombstone prevents that job from creating a confirmable draft.
  def handle_call({:refuse, actor, order, id}, _from, db) do
    result =
      with true <- valid_id?(actor) and valid_id?(id),
           {:ok, _record} <- get_order(db, order) do
        case query(db, "SELECT actor,order_id,status FROM proposals WHERE id=?", [id]) do
          [] ->
            query(db, "INSERT INTO proposals VALUES (?,?,?,?,?,'rejected',?,?)", [
              id,
              actor,
              order,
              "",
              0,
              now(),
              now()
            ])

            {:ok, :rejected}

          [[^actor, ^order, "pending"]] ->
            query(db, "UPDATE proposals SET status='rejected' WHERE id=?", [id])
            {:ok, :rejected}

          [[^actor, ^order, "rejected"]] ->
            {:ok, :rejected}

          [[^actor, ^order, "applied"]] ->
            {:error, :already_applied}

          [[^actor, ^order, _closed]] ->
            {:error, :closed}

          _other ->
            {:error, :not_found}
        end
      else
        false -> {:error, :invalid_argument}
        error -> error
      end

    {:reply, result, db}
  end

  @impl true
  def terminate(_reason, db), do: SQL.close(db)

  defp confirm_transaction(db, actor, id) do
    case query(
           db,
           "SELECT order_id,instructions,expected_version,status,expires_at FROM proposals WHERE id=? AND actor=?",
           [id, actor]
         ) do
      [[order, text, version, "applied", _expiry]] ->
        {:ok, %{order: order, instructions: text, version: version + 1, duplicate: true}}

      [[order, text, version, "pending", expiry]] ->
        with true <- expiry > now(), {:ok, %{version: ^version}} <- get_order(db, order) do
          query(
            db,
            "UPDATE orders SET instructions=?,version=version+1 WHERE id=? AND customer='demo' AND version=?",
            [text, order, version]
          )

          query(db, "INSERT INTO changes VALUES (?,?,?,?,?)", [
            id,
            order,
            text,
            version + 1,
            now()
          ])

          query(db, "UPDATE proposals SET status='applied' WHERE id=?", [id])
          {:ok, %{order: order, instructions: text, version: version + 1, duplicate: false}}
        else
          _invalid ->
            query(db, "UPDATE proposals SET status='expired_or_conflicting' WHERE id=?", [id])
            {:error, :conflict}
        end

      [] ->
        {:error, :not_found}

      _closed ->
        {:error, :conflict}
    end
  end

  defp all_orders(db),
    do:
      query(
        db,
        "SELECT id,status,tracking,items,instructions,version FROM orders WHERE customer='demo' ORDER BY id",
        []
      )
      |> Enum.map(&record/1)

  defp get_order(db, id) when is_binary(id) do
    case query(
           db,
           "SELECT id,status,tracking,items,instructions,version FROM orders WHERE customer='demo' AND id=?",
           [id]
         ) do
      [row] -> {:ok, record(row)}
      [] -> {:error, :not_found}
    end
  end

  defp get_order(_db, _id), do: {:error, :invalid_argument}

  defp record([id, status, tracking, items, text, version]),
    do: %{
      id: id,
      status: status,
      tracking: tracking,
      items: Jason.decode!(items),
      instructions: text,
      version: version
    }

  defp now, do: System.os_time(:second)
  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..128

  defp query(db, sql, values) do
    {:ok, statement} = SQL.prepare(db, sql)

    try do
      :ok = SQL.bind(statement, values)
      {:ok, rows} = SQL.fetch_all(db, statement)
      rows
    after
      SQL.release(db, statement)
    end
  end
end
