package constants

const (
	// ConsulCAFile is the location of the Consul CA file inside the injected pod.
	ConsulCAFile = "/consul/connect-inject/consul-ca.pem"

	// ProxyDefaultInboundPort is the default inbound port for the proxy.
	ProxyDefaultInboundPort = 20000

	// ProxyDefaultHealthPort is the default HTTP health check port for the proxy.
	ProxyDefaultHealthPort = 21000

	// MetaKeyKubeNS is the meta key name for Kubernetes namespace used for the Consul services.
	MetaKeyKubeNS = "k8s-namespace"

	// MetaKeyPodName is the meta key name for Kubernetes pod name used for the Consul services.
	MetaKeyPodName = "pod-name"

	// DefaultGracefulPort is the default port that consul-dataplane uses for graceful shutdown.
	DefaultGracefulPort = 20600

	// DefaultGracefulShutdownPath is the default path that consul-dataplane uses for graceful shutdown.
	DefaultGracefulShutdownPath = "/graceful_shutdown"
)
