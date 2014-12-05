@defstruct InnerProductLayer TrainableLayer (
  (name :: String = "", !isempty(name)),
  param_key :: String = "",
  (tops :: Vector{Symbol} = Symbol[], length(tops) >= 1),
  (bottoms :: Vector{Symbol} = Symbol[], length(bottoms) == length(tops)),
  (output_dim :: Int = 0, output_dim > 0),
  weight_init :: Initializer = XavierInitializer(),
  bias_init :: Initializer = ConstantInitializer(0),
  weight_regu :: Regularizer = L2Regu(1),
  bias_regu :: Regularizer = NoRegu(),
  weight_cons :: Constraint = NoCons(),
  bias_cons :: Constraint = NoCons(),
  weight_lr :: FloatingPoint = 1.0,
  bias_lr :: FloatingPoint = 2.0,
  neuron :: ActivationFunction = Neurons.Identity()
)

type InnerProductLayerState <: LayerState
  layer      :: InnerProductLayer
  blobs      :: Vector{Blob}
  blobs_diff :: Vector{Blob}

  parameters :: Vector{Parameter}

  W  :: Blob
  ∇W :: Blob
  b  :: Blob
  ∇b :: Blob

  # a all-1 vector used in gemm to help bias calculation
  bias_multiplier :: Blob

  InnerProductLayerState(backend::Backend, layer::InnerProductLayer, shared_params, inputs::Vector{Blob}) = begin
    dims = size(inputs[1])
    nums = dims[4]
    fea_dim = dims[1:3]
    fea_size = prod(fea_dim)
    out_dim = layer.output_dim

    data_type = eltype(inputs[1])
    blobs = Array(Blob, length(inputs))
    blobs_diff = Array(Blob, length(inputs))

    for i = 1:length(inputs)
      blobs[i] = make_blob(backend, data_type, 1, 1, out_dim, nums)
      blobs_diff[i] = make_blob(backend, data_type, 1, 1, out_dim, nums)
    end

    state = new(layer, blobs, blobs_diff)

    if shared_params != nothing
      @assert length(shared_params) == 2
      @assert shared_params[1].name == "weight" && shared_params[2].name == "bias"
      @assert size(shared_params[1].blob) == (fea_size, out_dim, 1, 1)
      @assert eltype(shared_params[1].blob) == data_type
      @debug("InnerProductLayer: sharing weights and bias")

      param_weight, param_bias = [share_parameter(backend, param) for param in shared_params]
    else
      param_weight = make_parameter(backend, "weight", data_type, (fea_size,out_dim,1,1),
          layer.weight_init, layer.weight_regu, layer.weight_cons, layer.weight_lr)
      param_bias   = make_parameter(backend, "bias", data_type, (out_dim, 1, 1, 1),
          layer.bias_init, layer.bias_regu, layer.bias_cons, layer.bias_lr)
    end

    state.W  = param_weight.blob
    state.∇W = param_weight.gradient
    state.b  = param_bias.blob
    state.∇b = param_bias.gradient
    state.parameters = [param_weight, param_bias]

    state.bias_multiplier = make_blob(backend, data_type, nums, 1, 1, 1)
    fill!(state.bias_multiplier, 1)

    return state
  end
end

function setup(backend::Backend, layer::InnerProductLayer, shared_state, inputs::Vector{Blob}, diffs::Vector{Blob})
  state = InnerProductLayerState(backend, layer, shared_state, inputs)
  return state
end
function setup(backend::Backend, layer::InnerProductLayer, inputs::Vector{Blob}, diffs::Vector{Blob})
  setup(backend, layer, nothing, inputs, diffs)
end
function shutdown(backend::Backend, state::InnerProductLayerState)
  map(destroy, state.blobs)
  map(destroy, state.blobs_diff)
  map(destroy, state.parameters)
end

function forward(backend::CPUBackend, state::InnerProductLayerState, inputs::Vector{Blob})
  M = size(state.W, 2)   # target dim
  N = size(inputs[1], 4) # batch size
  K = size(state.W, 1)   # source dim
  dtype = eltype(state.W)
  for i = 1:length(inputs)
    input = inputs[i]
    output = state.blobs[i]
    # output = W^T * X
    BLAS.gemm!('T', 'N', convert(dtype, 1), reshape(state.W.data, (K,M)),
                reshape(input.data, (K,N)), convert(dtype, 0), reshape(output.data, (M,N)))
    # output += bias
    BLAS.gemm!('N', 'N', convert(dtype, 1), reshape(state.b.data, (M,1)),
                reshape(state.bias_multiplier.data, (1,N)), convert(dtype, 1), reshape(output.data, (M,N)))
  end
end

function backward(backend::CPUBackend, state::InnerProductLayerState, inputs::Vector{Blob}, diffs::Vector{Blob})
  target_dim = size(state.W, 2)
  source_dim = size(state.W, 1)
  batch_size = size(inputs[1], 4)
  data_type  = eltype(state.W)

  # used in BLAS, at first it is zero, indicating overwriting the data
  # then it becomes one, indicating adding to the data
  zero_and_then_one = convert(data_type, 0)

  for i = 1:length(inputs)
    # ∂f/∂W = input * [∂f/∂o]^T
    input = inputs[i]
    ∂f_∂o = state.blobs_diff[i]
    BLAS.gemm!('N', 'T', convert(data_type, 1), reshape(input.data, (source_dim, batch_size)),
               reshape(∂f_∂o.data, (target_dim, batch_size)), zero_and_then_one,
               reshape(state.∇W.data, (source_dim, target_dim)))

    # ∂f/∂b = sum(∂f/∂o, 2)
    BLAS.gemm!('N', 'N', convert(data_type, 1), reshape(∂f_∂o.data, (target_dim, batch_size)),
               reshape(state.bias_multiplier.data, (batch_size, 1)), zero_and_then_one,
               reshape(state.∇b.data, (target_dim, 1)))

    zero_and_then_one = convert(data_type, 1)

    # if back propagate down
    if isa(diffs[i], CPUBlob)
      # ∂f/∂x = W * [∂f/∂o]
      BLAS.gemm!('N', 'N', convert(data_type, 1), reshape(state.W.data, (source_dim, target_dim)),
                 reshape(∂f_∂o.data, (target_dim, batch_size)), convert(data_type, 0),
                 reshape(diffs[i].data, (source_dim, batch_size)))
    end
  end
end

