defmodule Membrane.SRTP.Decryptor do
  @moduledoc """
  Converts SRTP packets to plain RTP.

  Requires adding [`:srtp`](https://github.com/membraneframework/elixir_srtp) dependency to work.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RTP}

  def_input_pad :input, caps: :any, demand_unit: :buffers
  def_output_pad :output, caps: RTP

  def_options policies: [
                spec: [SRTP.Policy.t()],
                description: """
                List of SRTP policies to use for decrypting packets.
                See `t:SRTP.Policy.t/0` for details.
                """
              ]

  @impl true
  def handle_init(options) do
    {:ok, Map.from_struct(options) |> Map.merge(%{srtp: nil})}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    srtp = SRTP.new()

    state.policies
    |> Bunch.listify()
    |> Enum.each(&SRTP.add_stream(srtp, &1))

    {:ok, %{state | srtp: srtp}}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    {:ok, %{state | srtp: nil}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {:ok, payload} = SRTP.unprotect(state.srtp, buffer.payload)
    {{:ok, buffer: {:output, %Buffer{buffer | payload: payload}}}, state}
  end
end
