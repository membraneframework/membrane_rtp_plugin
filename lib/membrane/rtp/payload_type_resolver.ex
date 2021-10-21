defmodule Membrane.RTP.PayloadFormatResolver do
  @moduledoc """
  Wrapper for `Membrane.RTP.PayloadFormat` extending its functionality for easier
  use with `membrane_rtp_plugin`.
  """

  alias Membrane.RTP
  alias Membrane.RTP.PayloadFormat

  @type encoding_mapper_t :: %{RTP.encoding_name_t() => module()}

  @doc """
  Tries to resolve a depayloader based on given encoding.
  """
  @spec depayloader(RTP.encoding_name_t(), custom_depayloaders :: encoding_mapper_t()) ::
          {:ok, module()} | :error
  def depayloader(encoding, custom_depayloaders \\ %{}) do
    case custom_depayloaders[encoding] || PayloadFormat.get(encoding).depayloader do
      nil -> :error
      depayloader -> {:ok, depayloader}
    end
  end

  @doc """
  Tries to resolve a payloader based on given encoding.
  """
  @spec payloader(RTP.encoding_name_t(), custom_payloaders :: encoding_mapper_t()) ::
          {:ok, module()} | :error
  def payloader(encoding, custom_payloaders \\ %{}) do
    case custom_payloaders[encoding] || PayloadFormat.get(encoding).payloader do
      nil -> :error
      payloader -> {:ok, payloader}
    end
  end
end
