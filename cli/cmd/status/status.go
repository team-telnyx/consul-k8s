package status

import (
	"errors"
	"fmt"
	"helm.sh/helm/v3/pkg/release"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"os"
	"sync"

	"github.com/hashicorp/consul-k8s/cli/cmd/common"
	"github.com/hashicorp/consul-k8s/cli/cmd/common/flag"
	"github.com/hashicorp/consul-k8s/cli/cmd/common/terminal"
	"helm.sh/helm/v3/pkg/action"
	helmCLI "helm.sh/helm/v3/pkg/cli"
	"k8s.io/client-go/kubernetes"
	"sigs.k8s.io/yaml"
)

type Command struct {
	*common.BaseCommand

	kubernetes 			kubernetes.Interface

	set 				*flag.Sets

	flagKubeConfig		string
	flagKubeContext		string

	once 				sync.Once
	help				string
}

func (c *Command) init() {
	c.set = flag.NewSets()
	{
		f := c.set.NewSet("Global Options")
		f.StringVar(&flag.StringVar{
			Name:    "kubeconfig",
			Aliases: []string{"c"},
			Target:  &c.flagKubeConfig,
			Default: "",
			Usage:   "Path to kubeconfig file.",
		})
		f.StringVar(&flag.StringVar{
			Name:    "context",
			Target:  &c.flagKubeContext,
			Default: "",
			Usage:   "Kubernetes context to use.",
		})
	}

	c.help = c.set.Help()

	// c.Init() calls the embedded BaseCommand's initialization function.
	c.Init()
}

func (c *Command) Run(args []string) int {
	c.once.Do(c.init)

	// The logger is initialized in main with the name cli. Here, we reset the name to status so log lines would be prefixed with status.
	c.Log.ResetNamed("status")

	defer func() {
		if err := c.Close(); err != nil {
			c.Log.Error(err.Error())
			os.Exit(1)
		}
	}()

	if err := c.validateFlags(args); err != nil {
		c.UI.Output(err.Error())
		return 1
	}

	// helmCLI.New() will create a settings object which is used by the Helm Go SDK calls.
	settings := helmCLI.New()
	if c.flagKubeConfig != "" {
		settings.KubeConfig = c.flagKubeConfig
	}
	if c.flagKubeContext != "" {
		settings.KubeContext = c.flagKubeContext
	}

	// Set up the kubernetes client to use for non Helm SDK calls to the Kubernetes API
	// The Helm SDK will use settings.RESTClientGetter for its calls as well, so this will
	// use a consistent method to target the right cluster for both Helm SDK and non Helm SDK calls.
	if c.kubernetes == nil {
		restConfig, err := settings.RESTClientGetter().ToRESTConfig()
		if err != nil {
			c.UI.Output("retrieving Kubernetes auth: %v", err, terminal.WithErrorStyle())
			return 1
		}
		c.kubernetes, err = kubernetes.NewForConfig(restConfig)
		if err != nil {
			c.UI.Output("initializing Kubernetes client: %v", err, terminal.WithErrorStyle())
			return 1
		}
	}

	// Setup logger to stream Helm library logs.
	var uiLogger = func(s string, args ...interface{}) {
		logMsg := fmt.Sprintf(s, args...)
		c.UI.Output(logMsg, terminal.WithLibraryStyle())
	}

	c.UI.Output("Consul-K8s Status Summary", terminal.WithHeaderStyle())
	releaseName, namespace, err := c.checkForPreviousInstallations(settings, uiLogger)
	if err != nil {
		c.UI.Output(err.Error(), terminal.WithErrorStyle())
		return 1
	}

	if err := c.checkHelmInstallation(settings, uiLogger, releaseName, namespace); err != nil {
		c.UI.Output(err.Error(), terminal.WithErrorStyle())
		return 1
	}

	if s, err := c.checkConsulServers(namespace); err != nil {
		c.UI.Output(err.Error(), terminal.WithErrorStyle())
		return 1
	} else {
		c.UI.Output(s, terminal.WithSuccessStyle())
	}

	if s, err := c.checkConsulClients(namespace); err != nil {
		c.UI.Output(err.Error(), terminal.WithErrorStyle())
		return 1
	} else {
		c.UI.Output(s, terminal.WithSuccessStyle())
	}






	return 0
}

// validateFlags is a helper function that performs sanity checks on the user's provided flags.
func (c *Command) validateFlags(args []string) error {
	if err := c.set.Parse(args); err != nil {
		return err
	}
	if len(c.set.Args()) > 0 {
		return errors.New("should have no non-flag arguments")
	}
	return nil
}

// checkForPreviousInstallations uses the helm Go SDK to find helm releases in all namespaces where the chart name is
// "consul", and returns the release name and namespace if found, or an error if not found.
func (c *Command) checkForPreviousInstallations(settings *helmCLI.EnvSettings, uiLogger action.DebugLog) (string, string, error) {
	// Need a specific action config to call helm list, where namespace is NOT specified.
	listConfig := new(action.Configuration)
	if err := listConfig.Init(settings.RESTClientGetter(), "",
		os.Getenv("HELM_DRIVER"), uiLogger); err != nil {
		return "", "", fmt.Errorf("couldn't initialize helm config: %s", err)
	}

	lister := action.NewList(listConfig)
	lister.AllNamespaces = true
	res, err := lister.Run()
	if err != nil {
		return "", "", fmt.Errorf("couldn't check for installations: %s", err)
	}

	for _, rel := range res {
		if rel.Chart.Metadata.Name == "consul" {
			c.UI.Output("Installation name: %s", rel.Name, terminal.WithInfoStyle())
			c.UI.Output("Namespace: %s", rel.Namespace, terminal.WithInfoStyle())
			return rel.Name, rel.Namespace, nil
		}
	}
	c.UI.Output("Consul installation found.", terminal.WithSuccessStyle())
	return "", "", errors.New("couldn't find installation")
}

// checkHelmInstallation uses the helm Go SDK to depict the status of a named release. This function then prints
// the version of the release, it's status (unknown, deployed, uninstalled, ...), and the overwritten values.
func (c *Command) checkHelmInstallation(settings *helmCLI.EnvSettings, uiLogger action.DebugLog, releaseName, namespace string) error {
	// Need a specific action config to call helm status, where namespace comes from the previous call to list.
	statusConfig := new(action.Configuration)
	if err := statusConfig.Init(settings.RESTClientGetter(), namespace,
		os.Getenv("HELM_DRIVER"), uiLogger); err != nil {
		return fmt.Errorf("couldn't initialize helm config: %s", err)
	}

	statuser := action.NewStatus(statusConfig)
	rel, err := statuser.Run(releaseName)
	if err != nil {
		return fmt.Errorf("couldn't check for installations: %s", err)
	}

	c.UI.Output("Status: %s", rel.Info.Status, terminal.WithInfoStyle())
	c.UI.Output("Version: %d", rel.Version, terminal.WithInfoStyle())
	c.UI.Output("Time Deployed: %v", rel.Info.LastDeployed, terminal.WithInfoStyle())

	valuesYaml, err := yaml.Marshal(rel.Config)
	if err != nil {
		c.UI.Output("Config:" + "\n" + "%+v", err, terminal.WithInfoStyle())
	} else if len(rel.Config) == 0 {
		c.UI.Output("Config: " + string(valuesYaml), terminal.WithInfoStyle())
	} else {
		c.UI.Output("Config:" + "\n" + string(valuesYaml), terminal.WithInfoStyle())
	}

	// Check the status of the hooks.
	if len(rel.Hooks) > 1 {
		c.UI.Output("Status Of Helm Hooks:")

		for _, hook := range rel.Hooks {
			// Remember that we only report the status of pre-install or pre-upgrade hooks.
			if validEvent(hook.Events) {
				c.UI.Output("%s %s: %s", hook.Name, hook.Kind, hook.LastRun.Phase.String())
			}
		}
		c.UI.Output("")
	}


	return nil
}

// Helper function that checks if the given hook's events are pre-install or pre-upgrade.
func validEvent(events []release.HookEvent) bool {
	for _, event := range events {
		if event.String() == "pre-install" || event.String() == "pre-upgrade" {
			return true
		}
	}
	return false
}

// checkConsulServers uses the Kubernetes list function to report if the consul servers are healthy.
func (c *Command) checkConsulServers(namespace string) (string, error) {
	servers, err := c.kubernetes.AppsV1().StatefulSets(namespace).List(c.Ctx,
		metav1.ListOptions{LabelSelector: "app=consul,chart=consul-helm,component=server"})
	if err != nil {
		return "", err
	} else if len(servers.Items) == 0 {
		return "", errors.New("no server stateful set found")
	} else if len(servers.Items) > 1 {
		return "", errors.New("found multiple server stateful sets")
	}

	desiredReplicas := int(*servers.Items[0].Spec.Replicas)
	readyReplicas := int(servers.Items[0].Status.ReadyReplicas)
	if readyReplicas < desiredReplicas {
		return "", fmt.Errorf("%d/%d Consul servers unhealthy", desiredReplicas - readyReplicas, desiredReplicas)
	}
	return fmt.Sprintf("Consul servers healthy (%d/%d)", readyReplicas, desiredReplicas), nil
}

// checkConsulClients uses the Kubernetes list function to report if the consul clients are healthy.
func (c *Command) checkConsulClients(namespace string) (string, error) {
	clients, err := c.kubernetes.AppsV1().DaemonSets(namespace).List(c.Ctx,
		metav1.ListOptions{LabelSelector: "app=consul,chart=consul-helm"})
	if err != nil {
		return "", err
	} else if len(clients.Items) == 0 {
		return "", errors.New("no client daemon set found")
	} else if len(clients.Items) > 1 {
		return "", errors.New("found multiple client daemon sets")
	}
	desiredReplicas := int(clients.Items[0].Status.DesiredNumberScheduled)
	readyReplicas := int(clients.Items[0].Status.NumberReady)
	if readyReplicas < desiredReplicas {
		return "", fmt.Errorf("%d/%d Consul clients unhealthy", desiredReplicas - readyReplicas, desiredReplicas)
	}
	return fmt.Sprintf("Consul clients healthy (%d/%d)", readyReplicas, desiredReplicas), nil
}

func (c *Command) Help() string {
	c.once.Do(c.init)
	s := "Usage: consul-k8s status" + "\n\n" + "Get the status of the current Consul installation." + "\n" +
		c.help
	return s
}

func (c *Command) Synopsis() string {
	return "Status of Consul-K8s install."
}