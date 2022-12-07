defmodule Membrane.RTP.Support.TestSource do
  @moduledoc false
  # Taken from RTC Engine - should be removed when core supports all features

  use Membrane.Source

  alias Membrane.Buffer
  alias Membrane.Element.Action

  @type generator ::
          (state :: any(), buffers_cnt :: pos_integer -> {[Action.t()], state :: any()})

  def_output_pad :output, caps: :any

  def_options output: [
                spec: {initial_state :: any(), generator} | Enum.t(),
                default: {0, &__MODULE__.default_buf_gen/2},
                description: """
                If `output` is an enumerable with `Membrane.Payload.t()` then
                buffer containing those payloads will be sent through the
                `:output` pad and followed by `t:Membrane.Element.Action.end_of_stream_t/0`.
                If `output` is a `{initial_state, function}` tuple then the
                the function will be invoked each time `handle_demand` is called.
                It is an action generator that takes two arguments.
                The first argument is the state that is initially set to
                `initial_state`. The second one defines the size of the demand.
                Such function should return `{actions, next_state}` where
                `actions` is a list of actions that will be returned from
                `handle_demand/4` and `next_state` is the value that will be
                used for the next call.
                """
              ],
              caps: [
                spec: struct(),
                default: %Membrane.RemoteStream{},
                description: """
                Caps to be sent before the `output`.
                """
              ],
              fast_start: [
                spec: boolean(),
                default: true,
                description: """
                Whether to start sending buffers immediately after going into
                playing state. If set to false, source has to be started
                manually by sending message `{:set_active, true}`.
                """
              ]

  @impl true
  def handle_init(opts) do
    opts = Map.from_struct(opts)

    case opts.output do
      {initial_state, generator} when is_function(generator) ->
        {:ok,
         opts
         |> Map.merge(%{
           generator_state: initial_state,
           output: generator,
           active?: opts.fast_start
         })}

      _enumerable_output ->
        {:ok, opts}
    end
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, caps: {:output, state.caps}}, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, %{active?: true} = state) do
    {actions, state} = get_actions(state, size)
    {{:ok, actions}, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_event(:output, event, _ctx, state) do
    {{:ok, notify: %Membrane.Testing.Notification{payload: {:event, event}}}, state}
  end

  @impl true
  def handle_other({:execute_actions, actions}, _ctx, state) do
    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:set_active, active?}, _ctx, state) do
    {{:ok, redemand: :output}, %{state | active?: active?}}
  end

  @spec default_buf_gen(integer(), integer()) :: {[Action.t()], integer()}
  def default_buf_gen(generator_state, size) do
    buffers =
      generator_state..(size + generator_state - 1)
      |> Enum.map(fn generator_state ->
        %Buffer{payload: <<generator_state::16>>}
      end)

    action = [buffer: {:output, buffers}]
    {action, generator_state + size}
  end

  @doc """
  Creates output with generator function from list of buffers.
  """
  @spec output_from_buffers([Buffer.t()]) :: {[Buffer.t()], generator()}
  def output_from_buffers(data) do
    fun = fn state, size ->
      {buffers, leftover} = Enum.split(state, size)
      buffer_action = [{:buffer, {:output, buffers}}]
      event_action = if leftover == [], do: [end_of_stream: :output], else: []
      to_send = buffer_action ++ event_action
      {to_send, leftover}
    end

    {data, fun}
  end

  defp get_actions(%{generator_state: generator_state, output: actions_generator} = state, size)
       when is_function(actions_generator) do
    {actions, generator_state} = actions_generator.(generator_state, size)
    {actions, %{state | generator_state: generator_state}}
  end

  defp get_actions(%{output: output} = state, size) do
    {payloads, output} = Enum.split(output, size)
    buffers = Enum.map(payloads, &%Buffer{payload: &1})

    actions =
      case output do
        [] -> [buffer: {:output, buffers}, end_of_stream: :output]
        _non_empty -> [buffer: {:output, buffers}]
      end

    {actions, %{state | output: output}}
  end
end