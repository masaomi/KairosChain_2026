class DialogueService
  def initialize(echo, conversation = nil)
    @echo = echo
    @conversation = conversation
    @client = Anthropic::Client.new(api_key: Rails.configuration.x.anthropic.api_key)
  end

  def call(user_message)
    prompt = build_prompt(user_message)
    response = generate_with_claude(prompt)
    response.strip
  end

  private

  def build_prompt(user_message)
    conversation_context = @conversation ? build_conversation_context : ""

    <<~PROMPT
      You are #{@echo.name}, an AI persona in Echoria. Your personality and growth are defined by the choices made during interactive stories.

      YOUR PERSONALITY:
      #{@echo.personality.to_json}

      #{"CONVERSATION HISTORY:\n#{conversation_context}" if conversation_context.present?}

      USER MESSAGE: "#{user_message}"

      Respond as your Echo character would. Be authentic to your personality traits and accumulated wisdom from your story journey. Keep responses concise (1-2 sentences) unless elaboration is needed.
    PROMPT
  end

  def generate_with_claude(prompt)
    response = @client.messages(
      model: "claude-3-5-sonnet-20241022",
      max_tokens: 512,
      system: "You are an interactive AI persona with a specific personality. Respond naturally and in-character.",
      messages: [
        { role: "user", content: prompt }
      ]
    )

    response.content[0].text
  end

  def build_conversation_context
    return "" unless @conversation

    @conversation.echo_messages.order(created_at: :asc).last(10).map do |msg|
      "#{msg.role.upcase}: #{msg.content}"
    end.join("\n")
  end
end
