defmodule Membrane.RTP.SRTP.Wrapper do
  @moduledoc false

  if Code.ensure_loaded?(ExLibSRTP) do
    require Membrane.Logger
    @type t :: ExLibSRTP.t() | nil

    @spec initialize([ExLibSRTP.Policy.t()]) :: t()
    def initialize(policies) do
      srtp = ExLibSRTP.new()
      Enum.each(policies, &ExLibSRTP.add_stream(srtp, &1))
      srtp
    end

    @spec protect(t(), binary()) :: binary() | nil
    def protect(srtp, packet) do
      case ExLibSRTP.protect(srtp, packet) do
        {:ok, packet} ->
          packet

        {:error, reason} when reason in [:replay_fail, :replay_old] ->
          Membrane.Logger.warning("Ignoring packet due to `#{reason}`")
          nil

        {:error, reason} ->
          raise "Failed to protect packet due to `#{reason}`"
      end
    end

    @spec unprotect(t(), binary()) :: binary() | nil
    def unprotect(srtp, packet) do
      case ExLibSRTP.unprotect(srtp, packet) do
        {:ok, packet} ->
          packet

        {:error, reason} when reason in [:replay_fail, :replay_old] ->
          Membrane.Logger.warning("Ignoring packet due to `#{reason}`")
          nil

        {:error, reason} ->
          raise "Failed to unprotect packet due to `#{reason}`"
      end
    end
  else
    @type t :: nil

    @spec initialize([term()]) :: no_return()
    def initialize(_policies) do
      raise "Optional dependency :ex_libsrtp is required for SRTP"
    end

    @spec protect(t(), binary()) :: no_return()
    def protect(_srtp, _packet) do
      raise "Optional dependency :ex_libsrtp is required for SRTP"
    end

    @spec unprotect(t(), binary()) :: no_return()
    def unprotect(_srtp, _packet) do
      raise "Optional dependency :ex_libsrtp is required for SRTP"
    end
  end
end
