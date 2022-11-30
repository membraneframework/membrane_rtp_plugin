if Code.ensure_loaded?(ExLibSRTP) do
  defmodule Membrane.SRTCP.Decryptor do
    @moduledoc """
    Converts SRTCP packets to plain RTCP.

    Requires adding [libsrtp](https://github.com/membraneframework/elixir_libsrtp) dependency to work.
    """
    use Membrane.Filter

    require Membrane.Logger

    alias Membrane.Buffer
    alias Membrane.SRTP

    def_input_pad :input, caps: :any, demand_mode: :auto
    def_output_pad :output, caps: :any, demand_mode: :auto

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
    def handle_process(:input, buffer, _ctx, state) do
      case ExLibSRTP.unprotect_rtcp(state.srtp, buffer.payload) do
        {:ok, payload} ->
          {{:ok, buffer: {:output, %Buffer{buffer | payload: payload}}}, state}

        {:error, reason} when reason in [:replay_fail, :replay_old] ->
          Membrane.Logger.debug("""
          Couldn't unprotect srtcp packet:
          #{inspect(buffer.payload, limit: :infinity)}
          Reason: #{inspect(reason)}. Ignoring packet.
          """)

          {:ok, state}

        {:error, reason} ->
          raise "Couldn't unprotect SRTCP packet due to #{inspect(reason)}"
      end
    end

    @impl true
    def handle_event(_pad, %SRTP.KeyingMaterialEvent{} = event, _ctx, %{policies: []} = state) do
      {:ok, crypto_profile} =
        ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(
          event.protection_profile
        )

      policy = %ExLibSRTP.Policy{
        ssrc: :any_inbound,
        key: event.remote_keying_material,
        rtp: crypto_profile,
        rtcp: crypto_profile
      }

      :ok = ExLibSRTP.add_stream(state.srtp, policy)
      {:ok, %{state | policies: [policy]}}
    end

    @impl true
    def handle_event(_pad, %SRTP.KeyingMaterialEvent{}, _ctx, state) do
      Membrane.Logger.warn("Got unexpected SRTP.KeyingMaterialEvent. Ignoring.")
      {:ok, state}
    end

    @impl true
    def handle_event(pad, event, ctx, state), do: super(pad, event, ctx, state)
  end
end
