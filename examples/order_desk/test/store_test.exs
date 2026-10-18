defmodule OrderDesk.StoreTest do
  use ExUnit.Case, async: true
  alias OrderDesk.Store

  test "confirmed updates persist, replay once, and reject cross-browser and stale drafts" do
    path =
      Path.join(System.tmp_dir!(), "order-desk-#{System.unique_integer([:positive])}.sqlite3")

    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    db = start_supervised!({Store, name: nil, path: path})
    assert {:ok, %{instructions: "", version: 1}} = Store.order("124", db)
    assert {:ok, _} = Store.propose("browser-A", "124", "Leave it at reception", "proposal-A", db)

    assert {:ok, _} =
             Store.propose("browser-A", "124", "Leave it with the neighbor", "proposal-B", db)

    assert {:error, :not_found} = Store.confirm("browser-B", "proposal-A", db)
    assert {:ok, %{instructions: ""}} = Store.order("124", db)

    assert {:error, :conflict} =
             Store.propose("browser-A", "123", "Wrong order", "proposal-A", db)

    assert {:ok, %{version: 2, duplicate: false}} = Store.confirm("browser-A", "proposal-A", db)
    assert {:ok, %{version: 2, duplicate: true}} = Store.confirm("browser-A", "proposal-A", db)
    assert {:error, :conflict} = Store.confirm("browser-A", "proposal-B", db)
    assert length(Store.dashboard("browser-A", db).changes) == 1
    assert :ok = stop_supervised(Store)
    restarted = start_supervised!({Store, name: nil, path: path})

    assert {:ok, %{instructions: "Leave it at reception", version: 2}} =
             Store.order("124", restarted)

    assert {:ok, %{duplicate: true}} = Store.confirm("browser-A", "proposal-A", restarted)
    assert length(Store.dashboard("browser-A", restarted).changes) == 1
  end

  test "reject, invalid input and unavailable order never mutate order records" do
    db = start_supervised!({Store, name: nil, path: ":memory:"})
    assert {:error, :invalid_argument} = Store.propose("actor", "124", "", "id", db)

    assert {:error, :invalid_argument} =
             Store.propose("actor", "124", String.duplicate("x", 301), "id", db)

    assert {:error, :not_found} = Store.propose("actor", "999", "test", "id", db)
    assert {:ok, _} = Store.propose("actor", "124", "test", "id", db)
    assert :ok = Store.reject("actor", "id", db)
    assert {:error, :conflict} = Store.confirm("actor", "id", db)
    assert Store.dashboard("actor", db).changes == []
  end

  test "expired drafts cannot be applied and concurrent confirms commit only once" do
    db = start_supervised!({Store, name: nil, path: ":memory:"})
    {:ok, _} = Store.propose("actor", "124", "Old instructions", "old", db)

    :ok =
      Exqlite.Sqlite3.execute(
        :sys.get_state(db),
        "UPDATE proposals SET expires_at=0 WHERE id='old'"
      )

    assert {:error, :conflict} = Store.confirm("actor", "old", db)
    {:ok, _} = Store.propose("actor", "124", "Current instructions", "current", db)

    results =
      1..8
      |> Task.async_stream(fn _ -> Store.confirm("actor", "current", db) end)
      |> Enum.to_list()

    assert Enum.count(results, &match?({:ok, {:ok, %{duplicate: false}}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, {:ok, %{duplicate: true}}}, &1)) == 7
    assert length(Store.dashboard("actor", db).changes) == 1
  end
end
