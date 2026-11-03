"""Process initialiser for pipeline workers. Must run before TensorFlow is imported in the child."""
import os


def init_worker(device, threads, gpu_mem_mb, cache_dir):
    os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
    os.environ["PYTHONWARNINGS"] = "ignore"
    if device == "cpu":
        os.environ["CUDA_VISIBLE_DEVICES"] = "-1"
    for k in ("OMP_NUM_THREADS", "TF_NUM_INTRAOP_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS"):
        os.environ[k] = str(threads)
    os.environ["TF_NUM_INTEROP_THREADS"] = "2"
    import warnings
    warnings.filterwarnings("ignore")
    import tensorflow as tf
    tf.get_logger().setLevel("ERROR")
    try:
        import absl.logging
        absl.logging.set_verbosity(absl.logging.ERROR)
    except ImportError:
        pass
    try:
        tf.config.threading.set_intra_op_parallelism_threads(threads)
        tf.config.threading.set_inter_op_parallelism_threads(2)
    except RuntimeError:
        pass
    if device == "gpu":
        gpus = tf.config.list_physical_devices("GPU")
        if gpus:
            tf.config.set_logical_device_configuration(
                gpus[0], [tf.config.LogicalDeviceConfiguration(memory_limit=int(gpu_mem_mb))])
    from . import datasets
    datasets.configure(cache_dir)
