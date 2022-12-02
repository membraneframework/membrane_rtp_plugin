defmodule Membrane.SRTP.Decryptor2 do
  @type t() :: %__MODULE__{
          policies: [ExLibSRTP.Policy.t()],
          srtp: ExLibSRTP.t()
        }

  @enforce_keys [:srtp]
  defstruct @enforce_keys ++ [policies: []]

  @spec new([ExLibSRTP.Policy.t()]) :: t()
  def new(policies) do
    srtp = ExLibSRTP.new()

    policies
    |> Bunch.listify()
    |> Enum.each(&ExLibSRTP.add_stream(srtp, &1))

    %__MODULE__{srtp: srtp, policies: policies}
  end

  @spec configure(t(), Membrane.SRTP.KeyingMaterialEvent.t()) ::
          {:ok, t()} | {:error, :already_configured}
  def configure(%__MODULE__{policies: []} = decryptor, event) do
    {:ok, crypto_profile} =
      ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(event.protection_profile)

    policy = %ExLibSRTP.Policy{
      ssrc: :any_inbound,
      key: event.remote_keying_material,
      rtp: crypto_profile,
      rtcp: crypto_profile
    }

    :ok = ExLibSRTP.add_stream(decryptor.srtp, policy)
    {:ok, %__MODULE__{decryptor | policies: [policy]}}
  end

  def configure(_decryptor, _event) do
    {:error, :already_configured}
  end

  @spec unprotect(t(), binary()) :: {:ok, binary()} | {:error, atom()}
  def unprotect(decryptor, payload) do
    ExLibSRTP.unprotect(decryptor.srtp, payload)
  end
end
