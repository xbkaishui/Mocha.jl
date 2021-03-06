function cuda_geometry(:: ActivationFunction, output :: Blob)
  len = length(output)

  x_block = int(ceil(float64(len)/128));
  return ((x_block,128), (len,))
end

############################################################
# Rectified-Linear
############################################################
function forward(backend :: GPUBackend, neuron :: Neurons.ReLU, output :: Blob)
  cuda_dim, blob_dim = cuda_geometry(neuron, output)
  data_type = eltype(output)
  if data_type == Float32
    kernel = backend.mocha.relu_forward_float
  elseif data_type == Float64
    kernel = backend.mocha.relu_forward_double
  else
    error("Unsupported data type $data_type")
  end
  CUDA.launch(kernel, cuda_dim..., tuple(output.ptr.p, blob_dim...))
end

function backward(backend :: GPUBackend, neuron :: Neurons.ReLU, output :: Blob, gradient :: Blob)
  cuda_dim, blob_dim = cuda_geometry(neuron, output)
  data_type = eltype(output)
  if data_type == Float32
    kernel = backend.mocha.relu_backward_float
  elseif data_type == Float64
    kernel = backend.mocha.relu_backward_double
  else
    error("Unsupported data type $data_type")
  end
  CUDA.launch(kernel, cuda_dim..., tuple(output.ptr.p, gradient.ptr.p, blob_dim...))
end


function forward(backend :: GPUBackend, neuron :: Neurons.Sigmoid, output :: Blob)
  cuda_dim, blob_dim = cuda_geometry(neuron, output)
  data_type = eltype(output)
  if data_type == Float32
    kernel = backend.mocha.sigmoid_forward_float
  elseif data_type == Float64
    kernel = backend.mocha.sigmoid_forward_double
  else
    error("Unsupported data type $data_type")
  end
  CUDA.launch(kernel, cuda_dim..., tuple(output.ptr.p, blob_dim...))
end

function backward(backend :: GPUBackend, neuron :: Neurons.Sigmoid, output :: Blob, gradient :: Blob)
  cuda_dim, blob_dim = cuda_geometry(neuron, output)
  data_type = eltype(output)
  if data_type == Float32
    kernel = backend.mocha.sigmoid_backward_float
  elseif data_type == Float64
    kernel = backend.mocha.sigmoid_backward_double
  else
    error("Unsupported data type $data_type")
  end
  CUDA.launch(kernel, cuda_dim..., tuple(output.ptr.p, gradient.ptr.p, blob_dim...))
end

