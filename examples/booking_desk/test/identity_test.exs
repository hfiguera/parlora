defmodule BookingDesk.IdentityTest do
  use ExUnit.Case, async: true
  alias BookingDesk.Identity

  defp state(text), do: %{dialogue: [%{speaker: :user, text: text}], latest_user: text}

  defp complete(
         name \\ "Jamie Rivera",
         dob \\ "1990-03-12",
         evidence \\ "March twelfth, nineteen ninety"
       ) do
    %{
      "status" => "complete",
      "full_name" => name,
      "dob" => dob,
      "name_evidence" => name,
      "dob_evidence" => [evidence]
    }
  end

  test "structured extraction preserves only names and dates supported by caller excerpts" do
    s = state("Yep, it's Jamie Rivera here. My birthday is March twelfth, nineteen ninety.")
    assert {:ok, %{name: "jamie rivera", dob: "1990-03-12"}} = Identity.validate(complete(), s)

    assert {:ok, %{name: "taylor o'neill", dob: "1985-07-24"}} =
             Identity.validate(
               complete(
                 "Taylor O’Neill",
                 "1985-07-24",
                 "July twenty-fourth, nineteen eighty-five"
               ),
               state("Taylor O’Neill. July twenty-fourth, nineteen eighty-five.")
             )

    for evidence <- [
          "March 12th, 1990",
          "03/12/1990",
          "1990-03-12",
          "the twelfth of March, nineteen ninety"
        ] do
      assert {:ok, %{dob: "1990-03-12"}} =
               Identity.validate(
                 complete("Jamie Rivera", "1990-03-12", evidence),
                 state("Jamie Rivera, #{evidence}")
               )
    end
  end

  test "a corrected year can cite separate exact caller excerpts" do
    s = state("Jamie Rivera. March twelfth, nineteen ninety. Sorry, nineteen ninety-one.")

    output = %{
      complete()
      | "dob" => "1991-03-12",
        "dob_evidence" => ["March twelfth", "nineteen ninety-one"]
    }

    assert {:ok, %{dob: "1991-03-12"}} = Identity.validate(output, s)
  end

  test "unsupported values, assistant-only evidence, invalid dates and extra fields cannot reach lookup" do
    s = state("Jamie Rivera, March twelfth, nineteen ninety.")

    for output <- [
          complete("Alex Morgan"),
          %{complete() | "dob" => "1991-03-12"},
          %{complete() | "name_evidence" => "my name is Jamie Rivera"},
          %{complete() | "dob_evidence" => ["March twelfth, nineteen ninety-one"]},
          Map.put(complete(), "patient", "p_1002"),
          %{complete() | "dob_evidence" => []},
          %{complete() | "name_evidence" => nil},
          %{complete() | "dob" => "1990-02-30"}
        ] do
      assert {:error, :invalid_extraction} = Identity.validate(output, s)
    end

    assistant = %{
      s
      | dialogue: [
          %{speaker: :assistant, text: "Jamie Rivera, March twelfth, nineteen ninety."},
          %{speaker: :user, text: "Sure"}
        ]
    }

    assert {:error, :invalid_extraction} = Identity.validate(complete(), assistant)

    for {dob, evidence} <- [
          {"1890-03-12", "March 12th, 1890"},
          {"2026-12-01", "December 1st, 2026"},
          {"2090-03-12", "March 12th, 2090"}
        ] do
      assert {:error, :invalid_extraction} =
               Identity.validate(
                 complete("Jamie Rivera", dob, evidence),
                 state("Jamie Rivera, #{evidence}")
               )
    end
  end

  test "missing and ambiguous fields remain incomplete without fixture defaults" do
    missing = %{complete() | "status" => "incomplete", "dob" => nil, "dob_evidence" => []}

    assert {:incomplete, [:dob], %{name: "jamie rivera", name_evidence: "Jamie Rivera"}} =
             Identity.validate(missing, state("Jamie Rivera"))

    assert {:incomplete, [:ambiguous]} =
             Identity.validate(%{missing | "status" => "ambiguous"}, state("Jamie Rivera"))

    assert Identity.requested?("Could I have your full name and date of birth?")
    refute Identity.requested?("Which doctor would you prefer?")
  end

  test "validated name and partial birth-date evidence survive outside the dialogue window" do
    retained = %{
      name: "jamie rivera",
      name_evidence: "Jamie Rivera",
      dob_evidence: ["March twelfth"]
    }

    s = state("nineteen ninety") |> Map.put(:retained_identity, retained)
    result = %{complete() | "dob_evidence" => ["March twelfth", "nineteen ninety"]}
    assert {:ok, %{name: "jamie rivera", dob: "1990-03-12"}} = Identity.validate(result, s)

    partial = %{
      complete()
      | "status" => "incomplete",
        "dob" => nil,
        "dob_evidence" => ["March twelfth"]
    }

    assert {:incomplete, [:dob], %{dob_evidence: ["March twelfth"]}} =
             Identity.validate(partial, state("Jamie Rivera, March twelfth"))
  end

  test "a new person cannot inherit the previous person's date of birth" do
    retained = %{
      name: "jamie rivera",
      name_evidence: "Jamie Rivera",
      dob: "1990-03-12",
      dob_evidence: ["March twelfth, nineteen ninety"]
    }

    s = state("Actually this is Alex Morgan") |> Map.put(:retained_identity, retained)

    assert {:incomplete, [:dob], %{name: "alex morgan"} = fields} =
             Identity.validate(complete("Alex Morgan"), s)

    refute Map.has_key?(fields, :dob)
  end
end
