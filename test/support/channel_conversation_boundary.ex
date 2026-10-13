defmodule Zaq.TestSupport.ChannelConversationBoundary do
  @moduledoc false

  # Contract fixtures go through the real closed Engine role boundary. There is
  # deliberately no conversation, identity or authorization logic in this helper.
  alias Zaq.Engine.Api
  alias Zaq.Event

  def initialize(scope, id \\ nil),
    do: dispatch(Map.merge(scope, %{operation: :initialize, conversation_id: id}))

  def history(scope, id, page \\ []),
    do: dispatch(Map.merge(scope, %{operation: :history, conversation_id: id, page: page}))

  def prepare(scope, incoming, context \\ nil),
    do:
      dispatch(
        Map.merge(scope, %{operation: :prepare, incoming: incoming, prompt_context: context})
      )

  defp dispatch(request) do
    event = Event.new(request, :engine, opts: [action: :channel_conversations])
    Api.handle_event(event, :channel_conversations, nil).response
  end
end
