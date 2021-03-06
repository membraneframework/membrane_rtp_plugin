defmodule Membrane.SRTP.Encryptor do
  @moduledoc """
  Converts plain RTP packets to SRTP.

  Requires adding [srtp](https://github.com/membraneframework/elixir_libsrtp) dependency to work.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.Buffer

  def_input_pad :input, caps: :any, demand_unit: :buffers
  def_output_pad :output, caps: :any

  def_options policies: [
                spec: [ExLibSRTP.Policy.t()],
                default: [],
                description: """
                List of SRTP policies to use for encrypting packets.
                See `t:ExLibSRTP.Policy.t/0` for details.
                """
              ]

  @impl true
  def handle_init(%__MODULE__{policies: policies}) do
    state = %{
      policies: policies,
      srtp: nil
    }

    {:ok, state}
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
    {:ok, %{state | srtp: nil, policies: []}}
  end

  @impl true
  def handle_event(_pad, %{handshake_data: handshake_data}, _ctx, %{policies: []} = state) do
    {local_keying_material, _remote_keying_material, protection_profile} = handshake_data

    {:ok, crypto_profile} =
      ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(protection_profile)

    policy = %ExLibSRTP.Policy{
      ssrc: :any_outbound,
      key: local_keying_material,
      rtp: crypto_profile,
      rtcp: crypto_profile
    }

    :ok = ExLibSRTP.add_stream(state.srtp, policy)
    {{:ok, redemand: :output}, Map.put(state, :policies, [policy])}
  end

  @impl true
  def handle_event(_pad, other, _ctx, state) do
    Membrane.Logger.warn("Got unexpected event: #{inspect(other)}. Ignoring.")
    {:ok, state}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, %{policies: []} = state) do
    {:ok, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    case ExLibSRTP.protect(state.srtp, buffer.payload) do
      {:ok, payload} ->
        {{:ok, buffer: {:output, %Buffer{buffer | payload: payload}}}, state}

      {:error, reason} ->
        Membrane.Logger.warn("""
        Couldn't protect payload:
        #{inspect(buffer.payload, limit: :infinity)}
        Reason: #{inspect(reason)}. Ignoring packet.
        """)

        {:ok, state}
    end
  end
end
