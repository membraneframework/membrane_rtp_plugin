defmodule Membrane.SRTCP.Decryptor do
  @moduledoc """
  Converts SRTCP packets to plain RTCP.

  Requires adding [libsrtp](https://github.com/membraneframework/elixir_libsrtp) dependency to work.
  """
  use Membrane.Filter

  alias Membrane.Buffer

  def_input_pad :input, caps: :any, demand_unit: :buffers
  def_output_pad :output, caps: :any

  def_options policies: [
                spec: [ExLibSRTP.Policy.t()],
                description: """
                List of SRTP policies to use for decrypting packets.
                See `t:ExLibSRTP.Policy.t/0` for details.
                """
              ]

  @impl true
  def handle_init(options) do
    {:ok, Map.from_struct(options) |> Map.merge(%{srtp: nil})}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    srtp = ExLibSRTP.new()

    state.policies
    |> Bunch.listify()
    |> Enum.each(&ExLibSRTP.add_stream(srtp, &1))

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
    {:ok, payload} = ExLibSRTP.unprotect_rtcp(state.srtp, buffer.payload)
    {{:ok, buffer: {:output, %Buffer{buffer | payload: payload}}}, state}
  end

  @impl true
  def handle_event(_pad, %{handshake_data: handshake_data}, _ctx, %{policies: []} = state) do
    {_local_keying_material, remote_keying_material, protection_profile} = handshake_data

    {:ok, crypto_profile} =
      ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(protection_profile)

    policy = %ExLibSRTP.Policy{
      ssrc: :any_inbound,
      key: remote_keying_material,
      rtp: crypto_profile,
      rtcp: crypto_profile
    }

    :ok = ExLibSRTP.add_stream(state.srtp, policy)
    {{:ok, redemand: :output}, %{state | policies: [policy]}}
  end

  @impl true
  def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)
end
