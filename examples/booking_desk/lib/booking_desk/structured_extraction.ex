defmodule BookingDesk.StructuredExtraction do
  @moduledoc "Bounded structured model requests; field validation stays with each extractor."

  def request(messages, schema, opts) do
    generate = Keyword.get(opts, :generate, &ReqLLM.generate_object/4)

    case generate.(Application.fetch_env!(:booking_desk, :identity_model), messages, schema,
           reasoning_effort: :none,
           max_completion_tokens: 256,
           receive_timeout: 4_000,
           total_timeout: 4_000,
           output_validation: :strict,
           openai_structured_output_mode: :json_schema,
           req_http_options: [retry: false],
           provider_options: [openai_json_schema_strict: true, store: false]
         ) do
      {:ok, %ReqLLM.Response{finish_reason: :stop} = response} ->
        {:ok, ReqLLM.Response.object(response)}

      _ ->
        {:error, :unavailable}
    end
  end
end
