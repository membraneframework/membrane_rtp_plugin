defmodule Membrane.RTP.RandomDropper do
  use Membrane.Filter

  def_input_pad :input, demand_unit: :buffers, caps: :any
  def_output_pad :output, caps: :any

  def_options drop_rate: [
                spec: float(),
                default: 0,
                description: "Probability for a buffer to get dropped in range (0, 1)"
              ]

  @impl true
  def handle_init(opts) do
    {:ok, %{drop_rate: opts.drop_rate}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    if :rand.uniform() < state.drop_rate do
      {{:ok, redemand: :output}, state}
    else
      {{:ok, buffer: {:output, buffer}, redemand: :output}, state}
    end
  end
end
