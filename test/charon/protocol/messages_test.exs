defmodule Charon.Protocol.MessagesTest do
  use ExUnit.Case, async: true

  alias Charon.Protocol.Messages

  describe "default_protocol_version/0" do
    test "returns the default protocol version" do
      assert Messages.default_protocol_version() == "2025-03-26"
    end
  end

  describe "initialize/3" do
    test "creates initialize message with client info and capabilities" do
      client_info = %{name: "TestClient", version: "1.0.0"}
      capabilities = %{"roots" => %{}}

      msg = Messages.initialize(capabilities, client_info)

      assert msg["method"] == "initialize"
      assert msg["params"]["protocolVersion"] == "2025-03-26"
      assert msg["params"]["clientInfo"][:name] == "TestClient"
      assert msg["params"]["clientInfo"][:version] == "1.0.0"
      assert msg["params"]["capabilities"]["roots"] == %{}
    end

    test "accepts custom protocol version" do
      msg = Messages.initialize("2024-11-05", %{}, %{name: "Test", version: "1.0"})

      assert msg["params"]["protocolVersion"] == "2024-11-05"
    end

    test "normalizes atom keys in capabilities to strings" do
      msg = Messages.initialize(%{roots: %{listChanged: true}}, %{name: "Test", version: "1.0"})

      assert msg["params"]["capabilities"]["roots"]["listChanged"] == true
    end
  end

  describe "initialized_notification/0" do
    test "creates initialized notification" do
      msg = Messages.initialized_notification()

      assert msg["method"] == "notifications/initialized"
    end
  end

  describe "ping/0" do
    test "creates ping message" do
      msg = Messages.ping()

      assert msg["method"] == "ping"
    end
  end

  describe "tools_list/1" do
    test "creates tools/list message without cursor" do
      msg = Messages.tools_list()

      assert msg["method"] == "tools/list"
      assert msg["params"] == %{}
    end

    test "creates tools/list message with cursor" do
      msg = Messages.tools_list("cursor123")

      assert msg["method"] == "tools/list"
      assert msg["params"]["cursor"] == "cursor123"
    end
  end

  describe "tools_call/2" do
    test "creates tools/call message" do
      msg = Messages.tools_call("my_tool", %{"arg1" => "value1"})

      assert msg["method"] == "tools/call"
      assert msg["params"]["name"] == "my_tool"
      assert msg["params"]["arguments"] == %{"arg1" => "value1"}
    end

    test "handles empty arguments" do
      msg = Messages.tools_call("simple_tool", %{})

      assert msg["params"]["arguments"] == %{}
    end
  end

  describe "resources_list/1" do
    test "creates resources/list message without cursor" do
      msg = Messages.resources_list()

      assert msg["method"] == "resources/list"
      assert msg["params"] == %{}
    end

    test "creates resources/list message with cursor" do
      msg = Messages.resources_list("page2")

      assert msg["params"]["cursor"] == "page2"
    end
  end

  describe "resources_read/1" do
    test "creates resources/read message" do
      msg = Messages.resources_read("file:///test/file.txt")

      assert msg["method"] == "resources/read"
      assert msg["params"]["uri"] == "file:///test/file.txt"
    end
  end

  describe "resources_subscribe/1" do
    test "creates resources/subscribe message" do
      msg = Messages.resources_subscribe("file:///watched")

      assert msg["method"] == "resources/subscribe"
      assert msg["params"]["uri"] == "file:///watched"
    end
  end

  describe "resources_unsubscribe/1" do
    test "creates resources/unsubscribe message" do
      msg = Messages.resources_unsubscribe("file:///watched")

      assert msg["method"] == "resources/unsubscribe"
      assert msg["params"]["uri"] == "file:///watched"
    end
  end

  describe "resources_templates_list/1" do
    test "creates resources/templates/list message" do
      msg = Messages.resources_templates_list()

      assert msg["method"] == "resources/templates/list"
    end

    test "includes cursor when provided" do
      msg = Messages.resources_templates_list("cursor")

      assert msg["params"]["cursor"] == "cursor"
    end
  end

  describe "prompts_list/1" do
    test "creates prompts/list message without cursor" do
      msg = Messages.prompts_list()

      assert msg["method"] == "prompts/list"
      assert msg["params"] == %{}
    end

    test "creates prompts/list message with cursor" do
      msg = Messages.prompts_list("next_page")

      assert msg["params"]["cursor"] == "next_page"
    end
  end

  describe "prompts_get/2" do
    test "creates prompts/get message without arguments" do
      msg = Messages.prompts_get("my_prompt")

      assert msg["method"] == "prompts/get"
      assert msg["params"]["name"] == "my_prompt"
      refute Map.has_key?(msg["params"], "arguments")
    end

    test "creates prompts/get message with arguments" do
      msg = Messages.prompts_get("my_prompt", %{"lang" => "elixir"})

      assert msg["params"]["name"] == "my_prompt"
      assert msg["params"]["arguments"] == %{"lang" => "elixir"}
    end
  end

  describe "logging_set_level/1" do
    test "creates logging/setLevel message" do
      msg = Messages.logging_set_level("debug")

      assert msg["method"] == "logging/setLevel"
      assert msg["params"]["level"] == "debug"
    end
  end

  describe "completion_complete/2" do
    test "creates completion/complete message" do
      ref = %{"type" => "ref/prompt", "name" => "test"}
      argument = %{"name" => "lang", "value" => "eli"}

      msg = Messages.completion_complete(ref, argument)

      assert msg["method"] == "completion/complete"
      assert msg["params"]["ref"] == ref
      assert msg["params"]["argument"] == argument
    end
  end

  describe "cancelled_notification/2" do
    test "creates cancelled notification without reason" do
      msg = Messages.cancelled_notification(123)

      assert msg["method"] == "notifications/cancelled"
      assert msg["params"]["requestId"] == 123
      refute Map.has_key?(msg["params"], "reason")
    end

    test "creates cancelled notification with reason" do
      msg = Messages.cancelled_notification(123, "User cancelled")

      assert msg["params"]["requestId"] == 123
      assert msg["params"]["reason"] == "User cancelled"
    end
  end

  describe "progress_notification/3" do
    test "creates progress notification" do
      msg = Messages.progress_notification("token123", 50, 100)

      assert msg["method"] == "notifications/progress"
      assert msg["params"]["progressToken"] == "token123"
      assert msg["params"]["progress"] == 50
      assert msg["params"]["total"] == 100
    end

    test "creates progress notification without total" do
      msg = Messages.progress_notification("token123", 50)

      assert msg["params"]["progress"] == 50
      refute Map.has_key?(msg["params"], "total")
    end
  end

  describe "roots_list_changed_notification/0" do
    test "creates roots/list_changed notification" do
      msg = Messages.roots_list_changed_notification()

      assert msg["method"] == "notifications/roots/list_changed"
    end
  end

  describe "ping_response/0" do
    test "creates empty ping response" do
      response = Messages.ping_response()

      assert response == %{}
    end
  end

  describe "roots_list_response/1" do
    test "creates roots list response" do
      roots = [%{"uri" => "file:///project", "name" => "Project"}]
      response = Messages.roots_list_response(roots)

      assert response["roots"] == roots
    end
  end

  describe "sampling_not_supported_error/0" do
    test "creates sampling not supported error" do
      error = Messages.sampling_not_supported_error()

      assert error["code"] == -32601
      assert error["message"] =~ "Sampling not supported"
    end
  end
end
