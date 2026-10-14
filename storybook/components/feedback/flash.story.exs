defmodule Storybook.Components.Feedback.Flash do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.FeedbackBanner.feedback_banner/1
  def description, do: "Inline action feedback banner. Supports info, warning and error states."

  def variations do
    [
      %Variation{
        id: :info,
        description: "Info",
        attributes: %{kind: :info, message: "Document ingestion completed successfully."}
      },
      %Variation{
        id: :error,
        description: "Error",
        attributes: %{kind: :error, message: "Something went wrong. Please try again."}
      },
      %Variation{
        id: :warning,
        description: "Persistent warning",
        attributes: %{
          kind: :warning,
          message: "Copy this key now. It will not be shown again.",
          auto_dismiss: false,
          dismissible: false
        }
      }
    ]
  end
end
