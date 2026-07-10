defmodule PhoenixKitManufacturing.Web.MachinesLiveTest do
  # Integration tests — require PostgreSQL, excluded when the DB is
  # unavailable (see test_helper.exs).
  use PhoenixKitManufacturing.LiveCase

  alias PhoenixKitManufacturing.Machines

  describe "list pages" do
    test "machines list renders the empty state", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/manufacturing/machines")
      assert html =~ "No machines yet."
    end

    test "types list renders the empty state", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/manufacturing/machines/types")
      assert html =~ "No machine types yet."
    end

    test "an existing machine appears in the list", %{conn: conn} do
      {:ok, _m} = Machines.create_machine(%{name: "CNC-01"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/manufacturing/machines")
      assert html =~ "CNC-01"
    end
  end

  describe "machine form" do
    test "creating a machine redirects to the list and persists it", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/manufacturing/machines/new")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("form", machine: %{name: "New Mill", status: "active"})
               |> render_submit()

      assert to =~ "manufacturing/machines"
      assert [%{name: "New Mill"}] = Machines.list_machines()
    end

    test "an invalid submit re-renders the form with an error", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/manufacturing/machines/new")

      html =
        view
        |> form("form", machine: %{name: "", status: "active"})
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
      assert Machines.count_machines() == 0
    end
  end

  describe "delete flow" do
    test "deleting a machine removes it from the list", %{conn: conn} do
      {:ok, machine} = Machines.create_machine(%{name: "To Delete"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/manufacturing/machines")

      view
      |> element(~s{button[phx-value-uuid="#{machine.uuid}"][phx-value-type="machine"]})
      |> render_click()

      html = render_click(view, "delete_machine", %{})
      assert html =~ "No machines yet."
      assert Machines.count_machines() == 0
    end
  end
end
