defmodule BookingDesk.IdentityLLMTest do
  use ExUnit.Case, async: true
  alias BookingDesk.Identity.LLM

  defp state do
    text = "Yep, Jamie Rivera here. March twelfth, nineteen ninety."

    %{
      dialogue: [
        %{speaker: :assistant, text: "Full name and date of birth?"},
        %{speaker: :user, text: text}
      ],
      latest_user: text,
      patient: "must-not-send",
      interpretation_binding: %{session_id: "private-session"}
    }
  end

  defp output,
    do: %{
      "status" => "complete",
      "full_name" => "Jamie Rivera",
      "dob" => "1990-03-12",
      "name_evidence" => "Jamie Rivera",
      "dob_evidence" => ["March twelfth, nineteen ninety"]
    }

  test "uses ReqLLM strict generation with bounded non-reasoning calls and no record candidates" do
    assert {:ok, %{name: "jamie rivera", dob: "1990-03-12"}} =
             LLM.extract(state(),
               generate: fn model, messages, schema, opts ->
                 assert model == "openai:gpt-6-luna"
                 assert opts[:reasoning_effort] == :none
                 assert opts[:max_completion_tokens] == 512
                 refute Keyword.has_key?(opts, :max_tokens)
                 assert opts[:output_validation] == :strict
                 assert opts[:total_timeout] == 4_000
                 assert opts[:req_http_options][:retry] == false
                 assert opts[:provider_options][:openai_json_schema_strict]
                 assert opts[:provider_options][:store] == false
                 assert schema["additionalProperties"] == false
                 assert Enum.sort(schema["required"]) == Enum.sort(Map.keys(output()))
                 refute inspect(messages) =~ "must-not-send"
                 refute inspect(messages) =~ "private-session"

                 {:ok,
                  %ReqLLM.Response{
                    id: "test",
                    model: "gpt-6-luna",
                    context: nil,
                    finish_reason: :stop,
                    object: output()
                  }}
               end
             )
  end

  test "refusal, truncation, malformed or unsupported results cannot produce demographics" do
    for response <- [
          {:error, :timeout},
          {:ok,
           %ReqLLM.Response{
             id: "test",
             model: "gpt-6-luna",
             context: nil,
             finish_reason: :length,
             object: output()
           }},
          {:ok,
           %ReqLLM.Response{
             id: "test",
             model: "gpt-6-luna",
             context: nil,
             finish_reason: :content_filter
           }},
          {:ok,
           %ReqLLM.Response{
             id: "test",
             model: "gpt-6-luna",
             context: nil,
             finish_reason: :stop,
             object: nil
           }},
          {:ok,
           %ReqLLM.Response{
             id: "test",
             model: "gpt-6-luna",
             context: nil,
             finish_reason: :stop,
             object: Map.put(output(), "full_name", "Alex Morgan")
           }}
        ] do
      assert {:error, _} = LLM.extract(state(), generate: fn _, _, _, _ -> response end)
    end
  end

  test "ReqLLM sends a native strict JSON schema rather than a tool or JSON-mode request" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = JSON.decode!(raw)
      send(parent, {:wire, body})

      response =
        if String.ends_with?(conn.request_path, "/responses") do
          %{
            "id" => "resp_test",
            "model" => "gpt-6-luna",
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "role" => "assistant",
                "content" => [
                  %{"type" => "output_text", "text" => JSON.encode!(output())}
                ]
              }
            ]
          }
        else
          %{
            "id" => "chatcmpl_test",
            "model" => "gpt-6-luna",
            "choices" => [
              %{
                "finish_reason" => "stop",
                "message" => %{"role" => "assistant", "content" => JSON.encode!(output())}
              }
            ]
          }
        end

      Req.Test.json(conn, response)
    end)

    assert {:ok, %{name: "jamie rivera", dob: "1990-03-12"}} =
             LLM.extract(state(),
               generate: fn model, messages, schema, opts ->
                 opts =
                   opts
                   |> Keyword.put(:api_key, "test-only")
                   |> Keyword.put(:req_http_options, plug: {Req.Test, __MODULE__}, retry: false)

                 ReqLLM.generate_object(model, messages, schema, opts)
               end
             )

    assert_receive {:wire, body}
    format = get_in(body, ["text", "format"]) || body["response_format"]
    assert format["type"] == "json_schema"
    definition = format["json_schema"] || format
    assert definition["strict"] == true
    assert definition["schema"]["additionalProperties"] == false
    assert body["store"] == false
    assert (get_in(body, ["reasoning", "effort"]) || body["reasoning_effort"]) == "none"
    refute Map.has_key?(body, "tools")
  end
end
