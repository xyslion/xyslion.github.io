---
title: "Kubernetes源码分析之kube-apiserver"
date: 2020-06-19T11:04:25+08:00
slug: k8s_apiserver_init
tags: ["k8s", "apiserver"]
categories: ["k8s"]
---

## Kubernetes源码分析之kube-apiserver

### 简略介绍

本节所有的代码基于最新的v1.18.4版本。

涉及到模块：
- [/cmd/kube-apiserver](https://github.com/kubernetes/kubernetes/tree/v1.18.4/cmd/kube-apiserver)
- [/pkg/master](https://github.com/kubernetes/kubernetes/tree/v1.18.4/pkg/master)
- [apiserver](https://github.com/kubernetes/kubernetes/tree/v1.18.4/staging/src/k8s.io/apiserver)
- [/pkg/registry](https://github.com/kubernetes/kubernetes/tree/v1.18.4/pkg/registry)
- [auth](https://github.com/kubernetes/kubernetes/tree/v1.18.4/plugin/pkg/auth)

**注：apiserver为kubernetes里的另一个project，但这里使用go module的replace功能重定向了kubernetes工程里的staging/src/k8s.io/apiserver里, 两处代码同步机制待研究**

### 启动分析

同Kubernetes所有的组件启动代码一致，apiserver启动使用的是cobra的命令行方式，代码位于[~/cmd/kube-apiserver/app/server.go](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L102)

```go
RunE: func(cmd *cobra.Command, args []string) error {
    verflag.PrintAndExitIfRequested()
    utilflag.PrintFlags(cmd.Flags())

    // set default options
    completedOptions, err := Complete(s)
    if err != nil {
        return err
    }

    // validate options
    if errs := completedOptions.Validate(); len(errs) != 0 {
        return utilerrors.NewAggregate(errs)
    }

    return Run(completedOptions, genericapiserver.SetupSignalHandler())
},
```

启动主要完成三个步骤：
1、完成参数的配置；
2、判断配置是否合法；
3、执行最终的Run方法。

[Run](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L146)方法的实现：
```go
// Run runs the specified APIServer.  This should never exit.
func Run(completeOptions completedServerRunOptions, stopCh <-chan struct{}) error {
	// To help debugging, immediately log version
	klog.Infof("Version: %+v", version.Get())

	server, err := CreateServerChain(completeOptions, stopCh)
	if err != nil {
		return err
	}

	prepared, err := server.PrepareRun()
	if err != nil {
		return err
	}

	return prepared.Run(stopCh)
}
```

主要执行两个步骤：
1、创建server端；
2、启动server。
因为apiserver本质上就是一个server服务器，所有代码核心就是如何配置server，包括路由、访问权限以及同数据库（etcd）的交互等。先看一下server端是如何创建起来的

### Server端创建

Server端的创建集中在[CreateServerChain](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L164)方法。方法代码如下：
```go
// CreateServerChain creates the apiservers connected via delegation.
func CreateServerChain(completedOptions completedServerRunOptions, stopCh <-chan struct{}) (*aggregatorapiserver.APIAggregator, error) {
	nodeTunneler, proxyTransport, err := CreateNodeDialer(completedOptions)
	if err != nil {
		return nil, err
	}

	kubeAPIServerConfig, insecureServingInfo, serviceResolver, pluginInitializer, err := CreateKubeAPIServerConfig(completedOptions, nodeTunneler, proxyTransport)
	if err != nil {
		return nil, err
	}

	// If additional API servers are added, they should be gated.
	apiExtensionsConfig, err := createAPIExtensionsConfig(*kubeAPIServerConfig.GenericConfig, kubeAPIServerConfig.ExtraConfig.VersionedInformers, pluginInitializer, completedOptions.ServerRunOptions, completedOptions.MasterCount,
		serviceResolver, webhook.NewDefaultAuthenticationInfoResolverWrapper(proxyTransport, kubeAPIServerConfig.GenericConfig.EgressSelector, kubeAPIServerConfig.GenericConfig.LoopbackClientConfig))
	if err != nil {
		return nil, err
	}
	apiExtensionsServer, err := createAPIExtensionsServer(apiExtensionsConfig, genericapiserver.NewEmptyDelegate())
	if err != nil {
		return nil, err
	}

	kubeAPIServer, err := CreateKubeAPIServer(kubeAPIServerConfig, apiExtensionsServer.GenericAPIServer)
	if err != nil {
		return nil, err
	}

	// aggregator comes last in the chain
	aggregatorConfig, err := createAggregatorConfig(*kubeAPIServerConfig.GenericConfig, completedOptions.ServerRunOptions, kubeAPIServerConfig.ExtraConfig.VersionedInformers, serviceResolver, proxyTransport, pluginInitializer)
	if err != nil {
		return nil, err
	}
	aggregatorServer, err := createAggregatorServer(aggregatorConfig, kubeAPIServer.GenericAPIServer, apiExtensionsServer.Informers)
	if err != nil {
		// we don't need special handling for innerStopCh because the aggregator server doesn't create any go routines
		return nil, err
	}

	if insecureServingInfo != nil {
		insecureHandlerChain := kubeserver.BuildInsecureHandlerChain(aggregatorServer.GenericAPIServer.UnprotectedHandler(), kubeAPIServerConfig.GenericConfig)
		if err := insecureServingInfo.Serve(insecureHandlerChain, kubeAPIServerConfig.GenericConfig.RequestTimeout, stopCh); err != nil {
			return nil, err
		}
	}

	return aggregatorServer, nil
}
```

创建过程主要有以下步骤：
1、根据配置构造apiserver的配置，调用方法[CreateKubeAPIServerConfig](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L268)；
2、根据配置构造扩展的apiserver的配置，调用方法为[createAPIExtensionsConfig](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/apiextensions.go#L40)；
3、创建server，包括扩展的apiserver和原生的apiserver，调用方法为[createAPIExtensionsServer](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/apiextensions.go#L101)和[CreateKubeAPIServer](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L213)。主要就是将各个handler的路由方法注册到Container中去，完全遵循[go-restful的设计模式](http://ernestmicklei.com/2012/11/go-restful-api-design/)，即将处理方法注册到Route中去，同一个根路径下的Route注册到WebService中去，WebService注册到Container中，Container负责分发。访问的过程为Container-->WebService-->Route。更加详细的go-restful使用可以参考其代码；
4、聚合server的配置和和创建。主要就是将原生的apiserver和扩展的apiserver的访问进行整合，添加后续的一些处理接口。调用方法为[createAggregatorConfig](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/aggregator.go#L57)和[createAggregatorServer](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/aggregator.go#L129)；
5、创建完成，返回配置的server信息。
以上几个步骤，最核心的就是apiserver如何创建，即如何按照go-restful的模式，添加路由和相应的处理方法，以[CreateKubeAPIServer](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L213)方法为例，[createAPIExtensionsServer](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/aggregator.go#L129)类似。

#### [CreateKubeAPIServer](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L213)

源码如下：
```go
// CreateKubeAPIServer creates and wires a workable kube-apiserver
func CreateKubeAPIServer(kubeAPIServerConfig *master.Config, delegateAPIServer genericapiserver.DelegationTarget) (*master.Master, error) {
	kubeAPIServer, err := kubeAPIServerConfig.Complete().New(delegateAPIServer)
	if err != nil {
		return nil, err
	}

	return kubeAPIServer, nil
}
```

通过[Complete](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/master/master.go#L286)方法完成配置的最终合法化，[New](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/master/master.go#L336)方法生成kubeAPIServer的配置，进入New方法:
```go
// New returns a new instance of Master from the given config.
// Certain config fields will be set to a default value if unset.
// Certain config fields must be specified, including:
//   KubeletClientConfig
func (c completedConfig) New(delegationTarget genericapiserver.DelegationTarget) (*Master, error) {
	if reflect.DeepEqual(c.ExtraConfig.KubeletClientConfig, kubeletclient.KubeletClientConfig{}) {
		return nil, fmt.Errorf("Master.New() called with empty config.KubeletClientConfig")
	}

	s, err := c.GenericConfig.New("kube-apiserver", delegationTarget)
	if err != nil {
		return nil, err
	}

	if c.ExtraConfig.EnableLogsSupport {
		routes.Logs{}.Install(s.Handler.GoRestfulContainer)
	}

	if utilfeature.DefaultFeatureGate.Enabled(features.ServiceAccountIssuerDiscovery) {
		// Metadata and keys are expected to only change across restarts at present,
		// so we just marshal immediately and serve the cached JSON bytes.
		md, err := serviceaccount.NewOpenIDMetadata(
			c.ExtraConfig.ServiceAccountIssuerURL,
			c.ExtraConfig.ServiceAccountJWKSURI,
			c.GenericConfig.ExternalAddress,
			c.ExtraConfig.ServiceAccountPublicKeys,
		)
		if err != nil {
			// If there was an error, skip installing the endpoints and log the
			// error, but continue on. We don't return the error because the
			// metadata responses require additional, backwards incompatible
			// validation of command-line options.
			msg := fmt.Sprintf("Could not construct pre-rendered responses for"+
				" ServiceAccountIssuerDiscovery endpoints. Endpoints will not be"+
				" enabled. Error: %v", err)
			if c.ExtraConfig.ServiceAccountIssuerURL != "" {
				// The user likely expects this feature to be enabled if issuer URL is
				// set and the feature gate is enabled. In the future, if there is no
				// longer a feature gate and issuer URL is not set, the user may not
				// expect this feature to be enabled. We log the former case as an Error
				// and the latter case as an Info.
				klog.Error(msg)
			} else {
				klog.Info(msg)
			}
		} else {
			routes.NewOpenIDMetadataServer(md.ConfigJSON, md.PublicKeysetJSON).
				Install(s.Handler.GoRestfulContainer)
		}
	}

	m := &Master{
		GenericAPIServer:          s,
		ClusterAuthenticationInfo: c.ExtraConfig.ClusterAuthenticationInfo,
	}

	// install legacy rest storage
	if c.ExtraConfig.APIResourceConfigSource.VersionEnabled(apiv1.SchemeGroupVersion) {
		legacyRESTStorageProvider := corerest.LegacyRESTStorageProvider{
			StorageFactory:              c.ExtraConfig.StorageFactory,
			ProxyTransport:              c.ExtraConfig.ProxyTransport,
			KubeletClientConfig:         c.ExtraConfig.KubeletClientConfig,
			EventTTL:                    c.ExtraConfig.EventTTL,
			ServiceIPRange:              c.ExtraConfig.ServiceIPRange,
			SecondaryServiceIPRange:     c.ExtraConfig.SecondaryServiceIPRange,
			ServiceNodePortRange:        c.ExtraConfig.ServiceNodePortRange,
			LoopbackClientConfig:        c.GenericConfig.LoopbackClientConfig,
			ServiceAccountIssuer:        c.ExtraConfig.ServiceAccountIssuer,
			ServiceAccountMaxExpiration: c.ExtraConfig.ServiceAccountMaxExpiration,
			APIAudiences:                c.GenericConfig.Authentication.APIAudiences,
		}
		if err := m.InstallLegacyAPI(&c, c.GenericConfig.RESTOptionsGetter, legacyRESTStorageProvider); err != nil {
			return nil, err
		}
	}

	// The order here is preserved in discovery.
	// If resources with identical names exist in more than one of these groups (e.g. "deployments.apps"" and "deployments.extensions"),
	// the order of this list determines which group an unqualified resource name (e.g. "deployments") should prefer.
	// This priority order is used for local discovery, but it ends up aggregated in `k8s.io/kubernetes/cmd/kube-apiserver/app/aggregator.go
	// with specific priorities.
	// TODO: describe the priority all the way down in the RESTStorageProviders and plumb it back through the various discovery
	// handlers that we have.
	restStorageProviders := []RESTStorageProvider{
		auditregistrationrest.RESTStorageProvider{},
		authenticationrest.RESTStorageProvider{Authenticator: c.GenericConfig.Authentication.Authenticator, APIAudiences: c.GenericConfig.Authentication.APIAudiences},
		authorizationrest.RESTStorageProvider{Authorizer: c.GenericConfig.Authorization.Authorizer, RuleResolver: c.GenericConfig.RuleResolver},
		autoscalingrest.RESTStorageProvider{},
		batchrest.RESTStorageProvider{},
		certificatesrest.RESTStorageProvider{},
		coordinationrest.RESTStorageProvider{},
		discoveryrest.StorageProvider{},
		extensionsrest.RESTStorageProvider{},
		networkingrest.RESTStorageProvider{},
		noderest.RESTStorageProvider{},
		policyrest.RESTStorageProvider{},
		rbacrest.RESTStorageProvider{Authorizer: c.GenericConfig.Authorization.Authorizer},
		schedulingrest.RESTStorageProvider{},
		settingsrest.RESTStorageProvider{},
		storagerest.RESTStorageProvider{},
		flowcontrolrest.RESTStorageProvider{},
		// keep apps after extensions so legacy clients resolve the extensions versions of shared resource names.
		// See https://github.com/kubernetes/kubernetes/issues/42392
		appsrest.RESTStorageProvider{},
		admissionregistrationrest.RESTStorageProvider{},
		eventsrest.RESTStorageProvider{TTL: c.ExtraConfig.EventTTL},
	}
	if err := m.InstallAPIs(c.ExtraConfig.APIResourceConfigSource, c.GenericConfig.RESTOptionsGetter, restStorageProviders...); err != nil {
		return nil, err
	}

	if c.ExtraConfig.Tunneler != nil {
		m.installTunneler(c.ExtraConfig.Tunneler, corev1client.NewForConfigOrDie(c.GenericConfig.LoopbackClientConfig).Nodes())
	}

	m.GenericAPIServer.AddPostStartHookOrDie("start-cluster-authentication-info-controller", func(hookContext genericapiserver.PostStartHookContext) error {
		kubeClient, err := kubernetes.NewForConfig(hookContext.LoopbackClientConfig)
		if err != nil {
			return err
		}
		controller := clusterauthenticationtrust.NewClusterAuthenticationTrustController(m.ClusterAuthenticationInfo, kubeClient)

		// prime values and start listeners
		if m.ClusterAuthenticationInfo.ClientCA != nil {
			if notifier, ok := m.ClusterAuthenticationInfo.ClientCA.(dynamiccertificates.Notifier); ok {
				notifier.AddListener(controller)
			}
			if controller, ok := m.ClusterAuthenticationInfo.ClientCA.(dynamiccertificates.ControllerRunner); ok {
				// runonce to be sure that we have a value.
				if err := controller.RunOnce(); err != nil {
					runtime.HandleError(err)
				}
				go controller.Run(1, hookContext.StopCh)
			}
		}
		if m.ClusterAuthenticationInfo.RequestHeaderCA != nil {
			if notifier, ok := m.ClusterAuthenticationInfo.RequestHeaderCA.(dynamiccertificates.Notifier); ok {
				notifier.AddListener(controller)
			}
			if controller, ok := m.ClusterAuthenticationInfo.RequestHeaderCA.(dynamiccertificates.ControllerRunner); ok {
				// runonce to be sure that we have a value.
				if err := controller.RunOnce(); err != nil {
					runtime.HandleError(err)
				}
				go controller.Run(1, hookContext.StopCh)
			}
		}

		go controller.Run(1, hookContext.StopCh)
		return nil
	})

	return m, nil
}
```

包含以下步骤：
1、按照`go-restful`的模式，调用[c.GenericConfig.New](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L523)方法初始化化Container，即`gorestfulContainer`，初始方法为[NewAPIServerHandler](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/handler.go#L73)。初始化之后，添加路由。

调用[installAPI](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L688)方法添加`apiserver`的基本路由信息
```go
func installAPI(s *GenericAPIServer, c *Config) {
	if c.EnableIndex {
		routes.Index{}.Install(s.listedPathProvider, s.Handler.NonGoRestfulMux)
	}
	if c.EnableProfiling {
		routes.Profiling{}.Install(s.Handler.NonGoRestfulMux)
		if c.EnableContentionProfiling {
			goruntime.SetBlockProfileRate(1)
		}
		// so far, only logging related endpoints are considered valid to add for these debug flags.
		routes.DebugFlags{}.Install(s.Handler.NonGoRestfulMux, "v", routes.StringFlagPutHandler(logs.GlogSetter))
	}
	if c.EnableMetrics {
		if c.EnableProfiling {
			routes.MetricsWithReset{}.Install(s.Handler.NonGoRestfulMux)
		} else {
			routes.DefaultMetrics{}.Install(s.Handler.NonGoRestfulMux)
		}
	}

	routes.Version{Version: c.Version}.Install(s.Handler.GoRestfulContainer)

	if c.EnableDiscovery {
		s.Handler.GoRestfulContainer.Add(s.DiscoveryGroupManager.WebService())
	}
}
```

该方法中添加了包括/、/debug/*、/metrics、/version几条路由，通过访问apiserver即可看到相关的信息

2、判断是否支持logs相关的路由，如果支持，则添加/logs路由；
3、添加[以api开头的路由](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/master/master.go#L389)
```go
// install legacy rest storage
if c.ExtraConfig.APIResourceConfigSource.VersionEnabled(apiv1.SchemeGroupVersion) {
	legacyRESTStorageProvider := corerest.LegacyRESTStorageProvider{
		StorageFactory:              c.ExtraConfig.StorageFactory,
		ProxyTransport:              c.ExtraConfig.ProxyTransport,
		KubeletClientConfig:         c.ExtraConfig.KubeletClientConfig,
		EventTTL:                    c.ExtraConfig.EventTTL,
		ServiceIPRange:              c.ExtraConfig.ServiceIPRange,
		SecondaryServiceIPRange:     c.ExtraConfig.SecondaryServiceIPRange,
		ServiceNodePortRange:        c.ExtraConfig.ServiceNodePortRange,
		LoopbackClientConfig:        c.GenericConfig.LoopbackClientConfig,
		ServiceAccountIssuer:        c.ExtraConfig.ServiceAccountIssuer,
		ServiceAccountMaxExpiration: c.ExtraConfig.ServiceAccountMaxExpiration,
		APIAudiences:                c.GenericConfig.Authentication.APIAudiences,
	}
	if err := m.InstallLegacyAPI(&c, c.GenericConfig.RESTOptionsGetter, legacyRESTStorageProvider); err != nil {
		return nil, err
	}
}
```
在集群中对应的路由有`/api、/api/v1`, 比较常用的资源像Pods就是该路由对应的资源；

4、添加[以apis开头的路由](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/master/master.go#L415)
```go
// The order here is preserved in discovery.
// If resources with identical names exist in more than one of these groups (e.g. "deployments.apps"" and "deployments.extensions"),
// the order of this list determines which group an unqualified resource name (e.g. "deployments") should prefer.
// This priority order is used for local discovery, but it ends up aggregated in `k8s.io/kubernetes/cmd/kube-apiserver/app/aggregator.go
// with specific priorities.
// TODO: describe the priority all the way down in the RESTStorageProviders and plumb it back through the various discovery
// handlers that we have.
restStorageProviders := []RESTStorageProvider{
	auditregistrationrest.RESTStorageProvider{},
	authenticationrest.RESTStorageProvider{Authenticator: c.GenericConfig.Authentication.Authenticator, APIAudiences: c.GenericConfig.Authentication.APIAudiences},
	authorizationrest.RESTStorageProvider{Authorizer: c.GenericConfig.Authorization.Authorizer, RuleResolver: c.GenericConfig.RuleResolver},
	autoscalingrest.RESTStorageProvider{},
	batchrest.RESTStorageProvider{},
	certificatesrest.RESTStorageProvider{},
	coordinationrest.RESTStorageProvider{},
	discoveryrest.StorageProvider{},
	extensionsrest.RESTStorageProvider{},
	networkingrest.RESTStorageProvider{},
	noderest.RESTStorageProvider{},
	policyrest.RESTStorageProvider{},
	rbacrest.RESTStorageProvider{Authorizer: c.GenericConfig.Authorization.Authorizer},
	schedulingrest.RESTStorageProvider{},
	settingsrest.RESTStorageProvider{},
	storagerest.RESTStorageProvider{},
	flowcontrolrest.RESTStorageProvider{},
	// keep apps after extensions so legacy clients resolve the extensions versions of shared resource names.
	// See https://github.com/kubernetes/kubernetes/issues/42392
	appsrest.RESTStorageProvider{},
	admissionregistrationrest.RESTStorageProvider{},
	eventsrest.RESTStorageProvider{TTL: c.ExtraConfig.EventTTL},
}
if err := m.InstallAPIs(c.ExtraConfig.APIResourceConfigSource, c.GenericConfig.RESTOptionsGetter, restStorageProviders...); err != nil {
	return nil, err
}

if c.ExtraConfig.Tunneler != nil {
	m.installTunneler(c.ExtraConfig.Tunneler, corev1client.NewForConfigOrDie(c.GenericConfig.LoopbackClientConfig).Nodes())
}
```
在集群中对应的路由有`/apis`开头的请求, 可以看到apis开头的路由明显较多。应该是由于kubernetes设计之初的版本都是以api/v1开头，后续扩展的版本以apis开头命名。现在更多的是通过CRD与自定义Controller的方法扩展API，不再进行api版本的扩展。基本上代码中的名称都可以在实际集群中找到对应的API。

#### 路由添加(api开头)

api开头的路由通过[InstallLegacyAPI](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/master/master.go#L487)方法添加。进入`InstallLegacyAPI`方法，如下：
```go
// InstallLegacyAPI will install the legacy APIs for the restStorageProviders if they are enabled.
func (m *Master) InstallLegacyAPI(c *completedConfig, restOptionsGetter generic.RESTOptionsGetter, legacyRESTStorageProvider corerest.LegacyRESTStorageProvider) error {
	legacyRESTStorage, apiGroupInfo, err := legacyRESTStorageProvider.NewLegacyRESTStorage(restOptionsGetter)
	if err != nil {
		return fmt.Errorf("error building core storage: %v", err)
	}

	controllerName := "bootstrap-controller"
	coreClient := corev1client.NewForConfigOrDie(c.GenericConfig.LoopbackClientConfig)
	bootstrapController := c.NewBootstrapController(legacyRESTStorage, coreClient, coreClient, coreClient, coreClient.RESTClient())
	m.GenericAPIServer.AddPostStartHookOrDie(controllerName, bootstrapController.PostStartHook)
	m.GenericAPIServer.AddPreShutdownHookOrDie(controllerName, bootstrapController.PreShutdownHook)

	if err := m.GenericAPIServer.InstallLegacyAPIGroup(genericapiserver.DefaultLegacyAPIPrefix, &apiGroupInfo); err != nil {
		return fmt.Errorf("error in registering group versions: %v", err)
	}
	return nil
}
```
通过[NewLegacyRESTStorage](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/registry/core/rest/storage_core.go#L102)方法创建各个资源的RESTStorage。RESTStorage是一个结构体，具体的实现了[Store](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/store.go#L81)接口，结构体内主要包含`NewFunc`返回特定资源信息、`NewListFunc`返回特定资源列表、`CreateStrategy`特定资源创建时的策略、`UpdateStrategy`更新时的策略以及`DeleteStrategy`删除时的策略等重要方法。
在`NewLegacyRESTStorage`内部，可以看到创建了多种资源的RESTStorage
```go
podTemplateStorage, err := podtemplatestore.NewREST(restOptionsGetter)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}

eventStorage, err := eventstore.NewREST(restOptionsGetter, uint64(c.EventTTL.Seconds()))
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}
limitRangeStorage, err := limitrangestore.NewREST(restOptionsGetter)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}

resourceQuotaStorage, resourceQuotaStatusStorage, err := resourcequotastore.NewREST(restOptionsGetter)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}
secretStorage, err := secretstore.NewREST(restOptionsGetter)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}
persistentVolumeStorage, persistentVolumeStatusStorage, err := pvstore.NewREST(restOptionsGetter)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}
persistentVolumeClaimStorage, persistentVolumeClaimStatusStorage, err := pvcstore.NewREST(restOptionsGetter)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}
configMapStorage, err := configmapstore.NewREST(restOptionsGetter)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}

namespaceStorage, namespaceStatusStorage, namespaceFinalizeStorage, err := namespacestore.NewREST(restOptionsGetter)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}

endpointsStorage, err := endpointsstore.NewREST(restOptionsGetter)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}

nodeStorage, err := nodestore.NewStorage(restOptionsGetter, c.KubeletClientConfig, c.ProxyTransport)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}

podStorage, err := podstore.NewStorage(
	restOptionsGetter,
	nodeStorage.KubeletConnectionInfo,
	c.ProxyTransport,
	podDisruptionClient,
)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}

var serviceAccountStorage *serviceaccountstore.REST
if c.ServiceAccountIssuer != nil && utilfeature.DefaultFeatureGate.Enabled(features.TokenRequest) {
	serviceAccountStorage, err = serviceaccountstore.NewREST(restOptionsGetter, c.ServiceAccountIssuer, c.APIAudiences, c.ServiceAccountMaxExpiration, podStorage.Pod.Store, secretStorage.Store)
} else {
	serviceAccountStorage, err = serviceaccountstore.NewREST(restOptionsGetter, nil, nil, 0, nil, nil)
}
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}

serviceRESTStorage, serviceStatusStorage, err := servicestore.NewGenericREST(restOptionsGetter)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}

var serviceClusterIPRegistry rangeallocation.RangeRegistry
serviceClusterIPRange := c.ServiceIPRange
if serviceClusterIPRange.IP == nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, fmt.Errorf("service clusterIPRange is missing")
}

serviceStorageConfig, err := c.StorageFactory.NewConfig(api.Resource("services"))
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}

serviceClusterIPAllocator, err := ipallocator.NewAllocatorCIDRRange(&serviceClusterIPRange, func(max int, rangeSpec string) (allocator.Interface, error) {
	mem := allocator.NewAllocationMap(max, rangeSpec)
	// TODO etcdallocator package to return a storage interface via the storageFactory
	etcd, err := serviceallocator.NewEtcd(mem, "/ranges/serviceips", api.Resource("serviceipallocations"), serviceStorageConfig)
	if err != nil {
		return nil, err
	}
	serviceClusterIPRegistry = etcd
	return etcd, nil
})
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, fmt.Errorf("cannot create cluster IP allocator: %v", err)
}
restStorage.ServiceClusterIPAllocator = serviceClusterIPRegistry

// allocator for secondary service ip range
var secondaryServiceClusterIPAllocator ipallocator.Interface
if utilfeature.DefaultFeatureGate.Enabled(features.IPv6DualStack) && c.SecondaryServiceIPRange.IP != nil {
	var secondaryServiceClusterIPRegistry rangeallocation.RangeRegistry
	secondaryServiceClusterIPAllocator, err = ipallocator.NewAllocatorCIDRRange(&c.SecondaryServiceIPRange, func(max int, rangeSpec string) (allocator.Interface, error) {
		mem := allocator.NewAllocationMap(max, rangeSpec)
		// TODO etcdallocator package to return a storage interface via the storageFactory
		etcd, err := serviceallocator.NewEtcd(mem, "/ranges/secondaryserviceips", api.Resource("serviceipallocations"), serviceStorageConfig)
		if err != nil {
			return nil, err
		}
		secondaryServiceClusterIPRegistry = etcd
		return etcd, nil
	})
	if err != nil {
		return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, fmt.Errorf("cannot create cluster secondary IP allocator: %v", err)
	}
	restStorage.SecondaryServiceClusterIPAllocator = secondaryServiceClusterIPRegistry
}

var serviceNodePortRegistry rangeallocation.RangeRegistry
serviceNodePortAllocator, err := portallocator.NewPortAllocatorCustom(c.ServiceNodePortRange, func(max int, rangeSpec string) (allocator.Interface, error) {
	mem := allocator.NewAllocationMap(max, rangeSpec)
	// TODO etcdallocator package to return a storage interface via the storageFactory
	etcd, err := serviceallocator.NewEtcd(mem, "/ranges/servicenodeports", api.Resource("servicenodeportallocations"), serviceStorageConfig)
	if err != nil {
		return nil, err
	}
	serviceNodePortRegistry = etcd
	return etcd, nil
})
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, fmt.Errorf("cannot create cluster port allocator: %v", err)
}
restStorage.ServiceNodePortAllocator = serviceNodePortRegistry

controllerStorage, err := controllerstore.NewStorage(restOptionsGetter)
if err != nil {
	return LegacyRESTStorage{}, genericapiserver.APIGroupInfo{}, err
}

serviceRest, serviceRestProxy := servicestore.NewREST(serviceRESTStorage,
	endpointsStorage,
	podStorage.Pod,
	serviceClusterIPAllocator,
	secondaryServiceClusterIPAllocator,
	serviceNodePortAllocator,
	c.ProxyTransport)
```

常见的像event、secret、namespace、endpoints等，统一调用`NewREST`方法构造相应的资源。待所有资源的store创建完成之后，使用`restStorageMap`的Map类型将每个资源的路由和对应的store对应起来，方便后续去做路由的统一规划，代码如下：
```go
restStorageMap := map[string]rest.Storage{
	"pods":             podStorage.Pod,
	"pods/attach":      podStorage.Attach,
	"pods/status":      podStorage.Status,
	"pods/log":         podStorage.Log,
	"pods/exec":        podStorage.Exec,
	"pods/portforward": podStorage.PortForward,
	"pods/proxy":       podStorage.Proxy,
	"pods/binding":     podStorage.Binding,
	"bindings":         podStorage.LegacyBinding,

	"podTemplates": podTemplateStorage,

	"replicationControllers":        controllerStorage.Controller,
	"replicationControllers/status": controllerStorage.Status,

	"services":        serviceRest,
	"services/proxy":  serviceRestProxy,
	"services/status": serviceStatusStorage,

	"endpoints": endpointsStorage,

	"nodes":        nodeStorage.Node,
	"nodes/status": nodeStorage.Status,
	"nodes/proxy":  nodeStorage.Proxy,

	"events": eventStorage,

	"limitRanges":                   limitRangeStorage,
	"resourceQuotas":                resourceQuotaStorage,
	"resourceQuotas/status":         resourceQuotaStatusStorage,
	"namespaces":                    namespaceStorage,
	"namespaces/status":             namespaceStatusStorage,
	"namespaces/finalize":           namespaceFinalizeStorage,
	"secrets":                       secretStorage,
	"serviceAccounts":               serviceAccountStorage,
	"persistentVolumes":             persistentVolumeStorage,
	"persistentVolumes/status":      persistentVolumeStatusStorage,
	"persistentVolumeClaims":        persistentVolumeClaimStorage,
	"persistentVolumeClaims/status": persistentVolumeClaimStatusStorage,
	"configMaps":                    configMapStorage,

	"componentStatuses": componentstatus.NewStorage(componentStatusStorage{c.StorageFactory}.serversToValidate),
}

if legacyscheme.Scheme.IsVersionRegistered(schema.GroupVersion{Group: "autoscaling", Version: "v1"}) {
	restStorageMap["replicationControllers/scale"] = controllerStorage.Scale
}
if legacyscheme.Scheme.IsVersionRegistered(schema.GroupVersion{Group: "policy", Version: "v1beta1"}) {
	restStorageMap["pods/eviction"] = podStorage.Eviction
}
if serviceAccountStorage.Token != nil {
	restStorageMap["serviceaccounts/token"] = serviceAccountStorage.Token
}
if utilfeature.DefaultFeatureGate.Enabled(features.EphemeralContainers) {
	restStorageMap["pods/ephemeralcontainers"] = podStorage.EphemeralContainers
}
apiGroupInfo.VersionedResourcesStorageMap["v1"] = restStorageMap
```

最终完成以api开头的所有资源的RESTStorage操作。
创建完之后，则开始进行路由的安装，执行`InstallLegacyAPIGroup`方法，主要调用链为`InstallLegacyAPIGroup-->installAPIResources-->InstallREST-->Install-->registerResourceHandlers`，最终核心的路由构造在`registerResourceHandlers`方法内。这是一个非常复杂的方法，整个方法的代码在700行左右。方法的主要功能是通过上一步骤构造的RESTStorage判断该资源可以执行哪些操作（如create、update等），将其对应的操作存入到action，每一个action对应一个标准的rest操作，如create对应的action操作为POST、update对应的action操作为PUT。最终根据actions数组依次遍历，对每一个操作添加一个handler方法，注册到route中去，route注册到webservice中去，完美匹配go-restful的设计模式。

#### 路由添加(apis开头)

api开头的路由主要是对基础资源的路由实现，而对于其他附加的资源，如认证相关、网络相关等各种扩展的api资源，统一以apis开头命名，实现入口为`InstallAPIs`。
`InstallAPIs`与`InstallLegacyAPIGroup`主要的区别是获取RESTStorage的方式。对于api开头的路由来说，都是/api/v1这种统一的格式；而对于apis开头路由则不一样，它包含了多种不同的格式（Kubernetes代码内叫groupName），如/apis/apps、/apis/certificates.k8s.io等各种无规律的groupName。为此，kubernetes提供了一种[RESTStorageProvider](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/master/master.go#L515)的工厂模式的接口

```go
// RESTStorageProvider is a factory type for REST storage.
type RESTStorageProvider interface {
	GroupName() string
	NewRESTStorage(apiResourceConfigSource serverstorage.APIResourceConfigSource, restOptionsGetter generic.RESTOptionsGetter) (genericapiserver.APIGroupInfo, bool, error)
}
```

所有以apis开头的路由的资源都需要实现该接口。GroupName()方法获取到的就是类似于/apis/apps、/apis/certificates.k8s.io这样的groupName，NewRESTStorage方法获取到的是相对应的RESTStorage封装后的信息。

后续的操作和之前的步骤类似，通过构造go-restful格式的路由信息，完成创建，此处不做赘述。

### Server端启动

通过[CreateServerChain](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L164)创建完server后，继续调用[GenericAPIServer](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/genericapiserver.go#L87)的[Run](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/genericapiserver.go#L316)方法完成最终的启动工作。首先通过[PrepareRun](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/genericapiserver.go#L283)方法完成启动前的路由收尾工作，该方法主要完成了`Swagger`和`OpenAPI`路由的注册工作（`Swagger`和`OpenAPI`主要包含了Kubernetes API的所有细节与规范），并完成/healthz路由的注册工作。完成后，开始最终的server启动工作。
`Run`方法里通过[NonBlockingRun](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/genericapiserver.go#L357)方法启动安全的http server（非安全方式的启动在[CreateServerChain](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L164)方法已经完成）
```go
// Run spawns the secure http server. It only returns if stopCh is closed
// or the secure port cannot be listened on initially.
func (s preparedGenericAPIServer) Run(stopCh <-chan struct{}) error {
	delayedStopCh := make(chan struct{})

	go func() {
		defer close(delayedStopCh)
		<-stopCh

		time.Sleep(s.ShutdownDelayDuration)
	}()

	// close socket after delayed stopCh
	err := s.NonBlockingRun(delayedStopCh)
	if err != nil {
		return err
	}

	<-stopCh

	// run shutdown hooks directly. This includes deregistering from the kubernetes endpoint in case of kube-apiserver.
	err = s.RunPreShutdownHooks()
	if err != nil {
		return err
	}

	// wait for the delayed stopCh before closing the handler chain (it rejects everything after Wait has been called).
	<-delayedStopCh

	// Wait for all requests to finish, which are bounded by the RequestTimeout variable.
	s.HandlerChainWaitGroup.Wait()

	return nil
}
```

启动主要工作包括配置各种证书认证、时间参数、报文大小参数之类，之后通过调用net/http库的启动方式启动，代码比较简洁，不一一列出了。

### 权限相关

ApiServer中与权限相关的主要有三种机制，即常用的认证、鉴权和准入控制。对apiserver来说，主要提供的就是rest风格的接口，所以各种权限最终还是集中到对接口的权限判断上。
以最核心的`kubeAPIServerConfig`(是一个[Config](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/master/master.go#L203)实例)举例，在[CreateServerChain](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L164)方法中，调用了[CreateKubeAPIServerConfig](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L268)的方法，该方法主要的作用是创建kubeAPIServer的配置。进入该方法，调用了[buildGenericConfig](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L412)创建一些通用的配置，在[NewConfig](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L288)生成一个[Config](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L84)实例，其中的[`BuildHandlerChainFunc`](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L140)属性的值为[DefaultBuildHandlerChain](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L664)，该方法主要就是用来对apiserver rest接口的链式判断，即俗称的filter操作，先记录下，后续分析。
```go
func DefaultBuildHandlerChain(apiHandler http.Handler, c *Config) http.Handler {
	handler := genericapifilters.WithAuthorization(apiHandler, c.Authorization.Authorizer, c.Serializer)
	if c.FlowControl != nil {
		handler = genericfilters.WithPriorityAndFairness(handler, c.LongRunningFunc, c.FlowControl)
	} else {
		handler = genericfilters.WithMaxInFlightLimit(handler, c.MaxRequestsInFlight, c.MaxMutatingRequestsInFlight, c.LongRunningFunc)
	}
	handler = genericapifilters.WithImpersonation(handler, c.Authorization.Authorizer, c.Serializer)
	handler = genericapifilters.WithAudit(handler, c.AuditBackend, c.AuditPolicyChecker, c.LongRunningFunc)
	failedHandler := genericapifilters.Unauthorized(c.Serializer, c.Authentication.SupportsBasicAuth)
	failedHandler = genericapifilters.WithFailedAuthenticationAudit(failedHandler, c.AuditBackend, c.AuditPolicyChecker)
	handler = genericapifilters.WithAuthentication(handler, c.Authentication.Authenticator, failedHandler, c.Authentication.APIAudiences)
	handler = genericfilters.WithCORS(handler, c.CorsAllowedOriginList, nil, nil, nil, "true")
	handler = genericfilters.WithTimeoutForNonLongRunningRequests(handler, c.LongRunningFunc, c.RequestTimeout)
	handler = genericfilters.WithWaitGroup(handler, c.LongRunningFunc, c.HandlerChainWaitGroup)
	handler = genericapifilters.WithRequestInfo(handler, c.RequestInfoResolver)
	if c.SecureServing != nil && !c.SecureServing.DisableHTTP2 && c.GoawayChance > 0 {
		handler = genericfilters.WithProbabilisticGoaway(handler, c.GoawayChance)
	}
	handler = genericapifilters.WithCacheControl(handler)
	handler = genericfilters.WithPanicRecovery(handler)
	return handler
}
```

配置文件创建完成后，再进行创建工作，进入到[CreateKubeAPIServer](https://github.com/kubernetes/kubernetes/blob/v1.18.4/cmd/kube-apiserver/app/server.go#L213)方法，然后一路跟踪下去([kubeAPIServerConfig](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/master/master.go#L203)--[Complete](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/master/master.go#L286)-->[CompletedConfig](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/master/master.go#L214)--[New](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/master/master.go#L336)-->[New](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L523))，会在初始化go-restful的Container的方法内，可以看到
```go
handlerChainBuilder := func(handler http.Handler) http.Handler {
	return c.BuildHandlerChainFunc(handler, c.Config)
}
apiServerHandler := NewAPIServerHandler(name, c.Serializer, handlerChainBuilder, delegationTarget.UnprotectedHandler())
```
`handlerChainBuilder`方法就是对返回的[DefaultBuildHandlerChain](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L664)方法的一种封装，并作为参数传入到[NewAPIServerHandler](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/handler.go#L73)方法内。进入[NewAPIServerHandler](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/handler.go#L73)方法，如下：
```go
func NewAPIServerHandler(name string, s runtime.NegotiatedSerializer, handlerChainBuilder HandlerChainBuilderFn, notFoundHandler http.Handler) *APIServerHandler {
	nonGoRestfulMux := mux.NewPathRecorderMux(name)
	if notFoundHandler != nil {
		nonGoRestfulMux.NotFoundHandler(notFoundHandler)
	}

	gorestfulContainer := restful.NewContainer()
	gorestfulContainer.ServeMux = http.NewServeMux()
	gorestfulContainer.Router(restful.CurlyRouter{}) // e.g. for proxy/{kind}/{name}/{*}
	gorestfulContainer.RecoverHandler(func(panicReason interface{}, httpWriter http.ResponseWriter) {
		logStackOnRecover(s, panicReason, httpWriter)
	})
	gorestfulContainer.ServiceErrorHandler(func(serviceErr restful.ServiceError, request *restful.Request, response *restful.Response) {
		serviceErrorHandler(s, serviceErr, request, response)
	})

	director := director{
		name:               name,
		goRestfulContainer: gorestfulContainer,
		nonGoRestfulMux:    nonGoRestfulMux,
	}

	return &APIServerHandler{
		FullHandlerChain:   handlerChainBuilder(director),
		GoRestfulContainer: gorestfulContainer,
		NonGoRestfulMux:    nonGoRestfulMux,
		Director:           director,
	}
}
```
配置中通过将`director`作为参数传到`handlerChainBuilder`的回调方法内，完成对gorestfulContainer的handler的注册工作。其实director就是一个实现了http.Handler的变量。所以，整个的处理逻辑就是将类型为http.Handler的director作为参数，传递到链式`filter`的[DefaultBuildHandlerChain](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L664)方法内。通过[DefaultBuildHandlerChain](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L664)对每一个步骤的`filter`操作，完成权限控制等之类的操作。后续就是做启动工作，包括证书验证、TLS认证之类的工作，不做过多赘述。主要看下`filter`的[DefaultBuildHandlerChain](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L664)方法是如何处理接口的鉴权操作。

### RBAC启动

Kubernetes中比较重要的用的比较多的可能就是RBAC了。在[DefaultBuildHandlerChain](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/server/config.go#L664)方法内，通过调用[genericapifilters.WithAuthorization](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/endpoints/filters/authorization.go#L45)方法，实现对每个接口的权限的`filter`操作。[WithAuthorization](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/endpoints/filters/authorization.go#L45)方法如下:
```go
// WithAuthorizationCheck passes all authorized requests on to handler, and returns a forbidden error otherwise.
func WithAuthorization(handler http.Handler, a authorizer.Authorizer, s runtime.NegotiatedSerializer) http.Handler {
	if a == nil {
		klog.Warningf("Authorization is disabled")
		return handler
	}
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		ctx := req.Context()
		ae := request.AuditEventFrom(ctx)

		attributes, err := GetAuthorizerAttributes(ctx)
		if err != nil {
			responsewriters.InternalError(w, req, err)
			return
		}
		authorized, reason, err := a.Authorize(ctx, attributes)
		// an authorizer like RBAC could encounter evaluation errors and still allow the request, so authorizer decision is checked before error here.
		if authorized == authorizer.DecisionAllow {
			audit.LogAnnotation(ae, decisionAnnotationKey, decisionAllow)
			audit.LogAnnotation(ae, reasonAnnotationKey, reason)
			handler.ServeHTTP(w, req)
			return
		}
		if err != nil {
			audit.LogAnnotation(ae, reasonAnnotationKey, reasonError)
			responsewriters.InternalError(w, req, err)
			return
		}

		klog.V(4).Infof("Forbidden: %#v, Reason: %q", req.RequestURI, reason)
		audit.LogAnnotation(ae, decisionAnnotationKey, decisionForbid)
		audit.LogAnnotation(ae, reasonAnnotationKey, reason)
		responsewriters.Forbidden(ctx, attributes, w, req, reason, s)
	})
}
```

1. 调用[GetAuthorizerAttributes](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/endpoints/filters/authorization.go#L80)方法获取配置的各种属性值；
2. 调用[Authorize](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/authorization/authorizer/interfaces.go#L71)方法判断权限是否通过，不同的权限实现其接口，完成鉴权任务;
3. 如果鉴权成功通过，则调用`handler.ServeHTTP`方法继续下一步的`filter`操作；否则，直接返回错误信息。
以RBAC为例，[Authorize](https://github.com/kubernetes/kubernetes/blob/v1.18.4/plugin/pkg/auth/authorizer/rbac/rbac.go#L75)方法最终调用[VisitRulesFor](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/registry/rbac/validation/rule.go#L178)方法实现权限的判断，VisitRulesFor主要代码如下:
```go
func (r *DefaultRuleResolver) VisitRulesFor(user user.Info, namespace string, visitor func(source fmt.Stringer, rule *rbacv1.PolicyRule, err error) bool) {
	if clusterRoleBindings, err := r.clusterRoleBindingLister.ListClusterRoleBindings(); err != nil {
		if !visitor(nil, nil, err) {
			return
		}
	} else {
		sourceDescriber := &clusterRoleBindingDescriber{}
		for _, clusterRoleBinding := range clusterRoleBindings {
			subjectIndex, applies := appliesTo(user, clusterRoleBinding.Subjects, "")
			if !applies {
				continue
			}
			rules, err := r.GetRoleReferenceRules(clusterRoleBinding.RoleRef, "")
			if err != nil {
				if !visitor(nil, nil, err) {
					return
				}
				continue
			}
			sourceDescriber.binding = clusterRoleBinding
			sourceDescriber.subject = &clusterRoleBinding.Subjects[subjectIndex]
			for i := range rules {
				if !visitor(sourceDescriber, &rules[i], nil) {
					return
				}
			}
		}
	}

	if len(namespace) > 0 {
		if roleBindings, err := r.roleBindingLister.ListRoleBindings(namespace); err != nil {
			if !visitor(nil, nil, err) {
				return
			}
		} else {
			sourceDescriber := &roleBindingDescriber{}
			for _, roleBinding := range roleBindings {
				subjectIndex, applies := appliesTo(user, roleBinding.Subjects, namespace)
				if !applies {
					continue
				}
				rules, err := r.GetRoleReferenceRules(roleBinding.RoleRef, namespace)
				if err != nil {
					if !visitor(nil, nil, err) {
						return
					}
					continue
				}
				sourceDescriber.binding = roleBinding
				sourceDescriber.subject = &roleBinding.Subjects[subjectIndex]
				for i := range rules {
					if !visitor(sourceDescriber, &rules[i], nil) {
						return
					}
				}
			}
		}
	}
}
```
主要工作就是对`clusterRoleBinding`以及`roleBinding`与配置的资源进行判断，比较清晰明了，这与我们使用RBAC的思路基本一致。

### 数据库操作

ApiServer与数据库的交互主要指的是与etcd的交互。Kubernetes所有的组件不直接与etcd交互，都是通过请求apiserver，apiserver与etcd进行交互完成数据的最终落盘。
在之前的路由实现已经说过，apiserver最终实现的handler对应的后端数据是以`Store`的结构保存的。这里以api开头的路由举例，在[NewLegacyRESTStorage](https://github.com/kubernetes/kubernetes/blob/v1.18.4/pkg/registry/core/rest/storage_core.go#L102)方法中，通过`NewREST`或者`NewStorage`会生成各种资源对应的Storage，以`endpoints`为例，生成的方法如下:
```go
// NewREST returns a RESTStorage object that will work against endpoints.
func NewREST(optsGetter generic.RESTOptionsGetter) (*REST, error) {
	store := &genericregistry.Store{
		NewFunc:                  func() runtime.Object { return &api.Endpoints{} },
		NewListFunc:              func() runtime.Object { return &api.EndpointsList{} },
		DefaultQualifiedResource: api.Resource("endpoints"),

		CreateStrategy: endpoint.Strategy,
		UpdateStrategy: endpoint.Strategy,
		DeleteStrategy: endpoint.Strategy,

		TableConvertor: printerstorage.TableConvertor{TableGenerator: printers.NewTableGenerator().With(printersinternal.AddHandlers)},
	}
	options := &generic.StoreOptions{RESTOptions: optsGetter}
	if err := store.CompleteWithOptions(options); err != nil {
		return nil, err
	}
	return &REST{store}, nil
}
```
主要看[CompleteWithOptions](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/store.go#L1206)方法，在[CompleteWithOptions](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/store.go#L1206)方法内，调用了[RESTOptions](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/generic/options.go#L29)的[GetRESTOptions](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/generic/options.go#L40)方法，依次调用[StorageWithCacher](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/storage_factory.go#L35)-->[NewRawStorage](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/generic/storage_decorator.go#L56)-->[Create](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/storage/storagebackend/factory/factory.go#L30)方法创建最终依赖的后端存储：
```go
// Create creates a storage backend based on given config.
func Create(c storagebackend.Config) (storage.Interface, DestroyFunc, error) {
	switch c.Type {
	case "etcd2":
		return nil, nil, fmt.Errorf("%v is no longer a supported storage backend", c.Type)
	case storagebackend.StorageTypeUnset, storagebackend.StorageTypeETCD3:
		return newETCD3Storage(c)
	default:
		return nil, nil, fmt.Errorf("unknown storage type: %s", c.Type)
	}
}
```
可以看到，通过[Create](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/storage/storagebackend/factory/factory.go#L30)方法判断是创建etcd2或是etcd3的后端etcd版本，目前版本默认的是etcd3。
创建完成对应的存储之后，接下来要做的工作就是将对应的handler方法和最终的后台存储实现绑定起来（handler方法处理最终的数据需要落盘）。
还记着之前说的有个比较长的方法[registerResourceHandlers](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/endpoints/installer.go#L181)，用来处理具体的handler路由。再次回到该方法，
```go
...
switch action.Verb {
case "GET": // Get a resource.
	var handler restful.RouteFunction
	if isGetterWithOptions {
		handler = restfulGetResourceWithOptions(getterWithOptions, reqScope, isSubresource)
	} else {
		handler = restfulGetResource(getter, exporter, reqScope)
	}

	if needOverride {
		// need change the reported verb
		handler = metrics.InstrumentRouteFunc(verbOverrider.OverrideMetricsVerb(action.Verb), group, version, resource, subresource, requestScope, metrics.APIServerComponent, handler)
	} else {
		handler = metrics.InstrumentRouteFunc(action.Verb, group, version, resource, subresource, requestScope, metrics.APIServerComponent, handler)
	}

	doc := "read the specified " + kind
	if isSubresource {
		doc = "read " + subresource + " of the specified " + kind
	}
	route := ws.GET(action.Path).To(handler).
		Doc(doc).
		Param(ws.QueryParameter("pretty", "If 'true', then the output is pretty printed.")).
		Operation("read"+namespaced+kind+strings.Title(subresource)+operationSuffix).
		Produces(append(storageMeta.ProducesMIMETypes(action.Verb), mediaTypes...)...).
		Returns(http.StatusOK, "OK", producedObject).
		Writes(producedObject)
	if isGetterWithOptions {
		if err := AddObjectParams(ws, route, versionedGetOptions); err != nil {
			return nil, err
		}
	}
	if isExporter {
		if err := AddObjectParams(ws, route, versionedExportOptions); err != nil {
			return nil, err
		}
	}
	addParams(route, action.Params)
	routes = append(routes, route)
case "LIST": // List all resources of a kind.
	doc := "list objects of kind " + kind
	if isSubresource {
		doc = "list " + subresource + " of objects of kind " + kind
	}
	handler := metrics.InstrumentRouteFunc(action.Verb, group, version, resource, subresource, requestScope, metrics.APIServerComponent, restfulListResource(lister, watcher, reqScope, false, a.minRequestTimeout))
	route := ws.GET(action.Path).To(handler).
		Doc(doc).
		Param(ws.QueryParameter("pretty", "If 'true', then the output is pretty printed.")).
		Operation("list"+namespaced+kind+strings.Title(subresource)+operationSuffix).
		Produces(append(storageMeta.ProducesMIMETypes(action.Verb), allMediaTypes...)...).
		Returns(http.StatusOK, "OK", versionedList).
		Writes(versionedList)
	if err := AddObjectParams(ws, route, versionedListOptions); err != nil {
		return nil, err
	}
	switch {
	case isLister && isWatcher:
		doc := "list or watch objects of kind " + kind
		if isSubresource {
			doc = "list or watch " + subresource + " of objects of kind " + kind
		}
		route.Doc(doc)
	case isWatcher:
		doc := "watch objects of kind " + kind
		if isSubresource {
			doc = "watch " + subresource + "of objects of kind " + kind
		}
		route.Doc(doc)
	}
	addParams(route, action.Params)
	routes = append(routes, route)
case "PUT": // Update a resource.
	doc := "replace the specified " + kind
	if isSubresource {
		doc = "replace " + subresource + " of the specified " + kind
	}
	handler := metrics.InstrumentRouteFunc(action.Verb, group, version, resource, subresource, requestScope, metrics.APIServerComponent, restfulUpdateResource(updater, reqScope, admit))
	route := ws.PUT(action.Path).To(handler).
		Doc(doc).
		Param(ws.QueryParameter("pretty", "If 'true', then the output is pretty printed.")).
		Operation("replace"+namespaced+kind+strings.Title(subresource)+operationSuffix).
		Produces(append(storageMeta.ProducesMIMETypes(action.Verb), mediaTypes...)...).
		Returns(http.StatusOK, "OK", producedObject).
		// TODO: in some cases, the API may return a v1.Status instead of the versioned object
		// but currently go-restful can't handle multiple different objects being returned.
		Returns(http.StatusCreated, "Created", producedObject).
		Reads(defaultVersionedObject).
		Writes(producedObject)
	if err := AddObjectParams(ws, route, versionedUpdateOptions); err != nil {
		return nil, err
	}
	addParams(route, action.Params)
	routes = append(routes, route)
case "PATCH": // Partially update a resource
	doc := "partially update the specified " + kind
	if isSubresource {
		doc = "partially update " + subresource + " of the specified " + kind
	}
	supportedTypes := []string{
		string(types.JSONPatchType),
		string(types.MergePatchType),
		string(types.StrategicMergePatchType),
	}
	if utilfeature.DefaultFeatureGate.Enabled(features.ServerSideApply) {
		supportedTypes = append(supportedTypes, string(types.ApplyPatchType))
	}
	handler := metrics.InstrumentRouteFunc(action.Verb, group, version, resource, subresource, requestScope, metrics.APIServerComponent, restfulPatchResource(patcher, reqScope, admit, supportedTypes))
	route := ws.PATCH(action.Path).To(handler).
		Doc(doc).
		Param(ws.QueryParameter("pretty", "If 'true', then the output is pretty printed.")).
		Consumes(supportedTypes...).
		Operation("patch"+namespaced+kind+strings.Title(subresource)+operationSuffix).
		Produces(append(storageMeta.ProducesMIMETypes(action.Verb), mediaTypes...)...).
		Returns(http.StatusOK, "OK", producedObject).
		Reads(metav1.Patch{}).
		Writes(producedObject)
	if err := AddObjectParams(ws, route, versionedPatchOptions); err != nil {
		return nil, err
	}
	addParams(route, action.Params)
	routes = append(routes, route)
case "POST": // Create a resource.
	var handler restful.RouteFunction
	if isNamedCreater {
		handler = restfulCreateNamedResource(namedCreater, reqScope, admit)
	} else {
		handler = restfulCreateResource(creater, reqScope, admit)
	}
	handler = metrics.InstrumentRouteFunc(action.Verb, group, version, resource, subresource, requestScope, metrics.APIServerComponent, handler)
	article := GetArticleForNoun(kind, " ")
	doc := "create" + article + kind
	if isSubresource {
		doc = "create " + subresource + " of" + article + kind
	}
	route := ws.POST(action.Path).To(handler).
		Doc(doc).
		Param(ws.QueryParameter("pretty", "If 'true', then the output is pretty printed.")).
		Operation("create"+namespaced+kind+strings.Title(subresource)+operationSuffix).
		Produces(append(storageMeta.ProducesMIMETypes(action.Verb), mediaTypes...)...).
		Returns(http.StatusOK, "OK", producedObject).
		// TODO: in some cases, the API may return a v1.Status instead of the versioned object
		// but currently go-restful can't handle multiple different objects being returned.
		Returns(http.StatusCreated, "Created", producedObject).
		Returns(http.StatusAccepted, "Accepted", producedObject).
		Reads(defaultVersionedObject).
		Writes(producedObject)
	if err := AddObjectParams(ws, route, versionedCreateOptions); err != nil {
		return nil, err
	}
	addParams(route, action.Params)
	routes = append(routes, route)
case "DELETE": // Delete a resource.
	article := GetArticleForNoun(kind, " ")
	doc := "delete" + article + kind
	if isSubresource {
		doc = "delete " + subresource + " of" + article + kind
	}
	deleteReturnType := versionedStatus
	if deleteReturnsDeletedObject {
		deleteReturnType = producedObject
	}
	handler := metrics.InstrumentRouteFunc(action.Verb, group, version, resource, subresource, requestScope, metrics.APIServerComponent, restfulDeleteResource(gracefulDeleter, isGracefulDeleter, reqScope, admit))
	route := ws.DELETE(action.Path).To(handler).
		Doc(doc).
		Param(ws.QueryParameter("pretty", "If 'true', then the output is pretty printed.")).
		Operation("delete"+namespaced+kind+strings.Title(subresource)+operationSuffix).
		Produces(append(storageMeta.ProducesMIMETypes(action.Verb), mediaTypes...)...).
		Writes(deleteReturnType).
		Returns(http.StatusOK, "OK", deleteReturnType).
		Returns(http.StatusAccepted, "Accepted", deleteReturnType)
	if isGracefulDeleter {
		route.Reads(versionedDeleterObject)
		route.ParameterNamed("body").Required(false)
		if err := AddObjectParams(ws, route, versionedDeleteOptions); err != nil {
			return nil, err
		}
	}
	addParams(route, action.Params)
	routes = append(routes, route)
case "DELETECOLLECTION":
	doc := "delete collection of " + kind
	if isSubresource {
		doc = "delete collection of " + subresource + " of a " + kind
	}
	handler := metrics.InstrumentRouteFunc(action.Verb, group, version, resource, subresource, requestScope, metrics.APIServerComponent, restfulDeleteCollection(collectionDeleter, isCollectionDeleter, reqScope, admit))
	route := ws.DELETE(action.Path).To(handler).
		Doc(doc).
		Param(ws.QueryParameter("pretty", "If 'true', then the output is pretty printed.")).
		Operation("deletecollection"+namespaced+kind+strings.Title(subresource)+operationSuffix).
		Produces(append(storageMeta.ProducesMIMETypes(action.Verb), mediaTypes...)...).
		Writes(versionedStatus).
		Returns(http.StatusOK, "OK", versionedStatus)
	if isCollectionDeleter {
		route.Reads(versionedDeleterObject)
		route.ParameterNamed("body").Required(false)
		if err := AddObjectParams(ws, route, versionedDeleteOptions); err != nil {
			return nil, err
		}
	}
	if err := AddObjectParams(ws, route, versionedListOptions); err != nil {
		return nil, err
	}
	addParams(route, action.Params)
	routes = append(routes, route)
// deprecated in 1.11
case "WATCH": // Watch a resource.
	doc := "watch changes to an object of kind " + kind
	if isSubresource {
		doc = "watch changes to " + subresource + " of an object of kind " + kind
	}
	doc += ". deprecated: use the 'watch' parameter with a list operation instead, filtered to a single item with the 'fieldSelector' parameter."
	handler := metrics.InstrumentRouteFunc(action.Verb, group, version, resource, subresource, requestScope, metrics.APIServerComponent, restfulListResource(lister, watcher, reqScope, true, a.minRequestTimeout))
	route := ws.GET(action.Path).To(handler).
		Doc(doc).
		Param(ws.QueryParameter("pretty", "If 'true', then the output is pretty printed.")).
		Operation("watch"+namespaced+kind+strings.Title(subresource)+operationSuffix).
		Produces(allMediaTypes...).
		Returns(http.StatusOK, "OK", versionedWatchEvent).
		Writes(versionedWatchEvent)
	if err := AddObjectParams(ws, route, versionedListOptions); err != nil {
		return nil, err
	}
	addParams(route, action.Params)
	routes = append(routes, route)
// deprecated in 1.11
case "WATCHLIST": // Watch all resources of a kind.
	doc := "watch individual changes to a list of " + kind
	if isSubresource {
		doc = "watch individual changes to a list of " + subresource + " of " + kind
	}
	doc += ". deprecated: use the 'watch' parameter with a list operation instead."
	handler := metrics.InstrumentRouteFunc(action.Verb, group, version, resource, subresource, requestScope, metrics.APIServerComponent, restfulListResource(lister, watcher, reqScope, true, a.minRequestTimeout))
	route := ws.GET(action.Path).To(handler).
		Doc(doc).
		Param(ws.QueryParameter("pretty", "If 'true', then the output is pretty printed.")).
		Operation("watch"+namespaced+kind+strings.Title(subresource)+"List"+operationSuffix).
		Produces(allMediaTypes...).
		Returns(http.StatusOK, "OK", versionedWatchEvent).
		Writes(versionedWatchEvent)
	if err := AddObjectParams(ws, route, versionedListOptions); err != nil {
		return nil, err
	}
	addParams(route, action.Params)
	routes = append(routes, route)
case "CONNECT":
	for _, method := range connecter.ConnectMethods() {
		connectProducedObject := storageMeta.ProducesObject(method)
		if connectProducedObject == nil {
			connectProducedObject = "string"
		}
		doc := "connect " + method + " requests to " + kind
		if isSubresource {
			doc = "connect " + method + " requests to " + subresource + " of " + kind
		}
		handler := metrics.InstrumentRouteFunc(action.Verb, group, version, resource, subresource, requestScope, metrics.APIServerComponent, restfulConnectResource(connecter, reqScope, admit, path, isSubresource))
		route := ws.Method(method).Path(action.Path).
			To(handler).
			Doc(doc).
			Operation("connect" + strings.Title(strings.ToLower(method)) + namespaced + kind + strings.Title(subresource) + operationSuffix).
			Produces("*/*").
			Consumes("*/*").
			Writes(connectProducedObject)
		if versionedConnectOptions != nil {
			if err := AddObjectParams(ws, route, versionedConnectOptions); err != nil {
				return nil, err
			}
		}
		addParams(route, action.Params)
		routes = append(routes, route)

		// transform ConnectMethods to kube verbs
		if kubeVerb, found := toDiscoveryKubeVerb[method]; found {
			if len(kubeVerb) != 0 {
				kubeVerbs[kubeVerb] = struct{}{}
			}
		}
	}
default:
	return nil, fmt.Errorf("unrecognized action verb: %s", action.Verb)
}
...
```
每个case语句代码一种请求类型和相对应的handler方法，以`POST`方法为例，对应的是Create操作。
```go
case "POST": // Create a resource.
	var handler restful.RouteFunction
	if isNamedCreater {
		handler = restfulCreateNamedResource(namedCreater, reqScope, admit)
	} else {
		handler = restfulCreateResource(creater, reqScope, admit)
	}
	handler = metrics.InstrumentRouteFunc(action.Verb, group, version, resource, subresource, requestScope, metrics.APIServerComponent, handler)
	article := GetArticleForNoun(kind, " ")
	doc := "create" + article + kind
	if isSubresource {
		doc = "create " + subresource + " of" + article + kind
	}
	route := ws.POST(action.Path).To(handler).
		Doc(doc).
		Param(ws.QueryParameter("pretty", "If 'true', then the output is pretty printed.")).
		Operation("create"+namespaced+kind+strings.Title(subresource)+operationSuffix).
		Produces(append(storageMeta.ProducesMIMETypes(action.Verb), mediaTypes...)...).
		Returns(http.StatusOK, "OK", producedObject).
		// TODO: in some cases, the API may return a v1.Status instead of the versioned object
		// but currently go-restful can't handle multiple different objects being returned.
		Returns(http.StatusCreated, "Created", producedObject).
		Returns(http.StatusAccepted, "Accepted", producedObject).
		Reads(defaultVersionedObject).
		Writes(producedObject)
	if err := AddObjectParams(ws, route, versionedCreateOptions); err != nil {
		return nil, err
	}
	addParams(route, action.Params)
	routes = append(routes, route)
```
`handler`参数的调用最终都会走到[createHandler]()方法处，位于[k8s.io/apiserver/pkg/endpoints/handlers/crete.go](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/endpoints/handlers/create.go#L145)下。最核心的步骤即调用了Create方法：
```go
requestFunc := func() (runtime.Object, error) {
	return r.Create(
		ctx,
		name,
		obj,
		rest.AdmissionToValidateObjectFunc(admit, admissionAttributes, scope),
		options,
	)
}
```
一步步走下去，最终调用的是位于`kubernetes/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/store.go`下的[Create](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/store.go#L338)方法。该方法主要包含[BeforeCreate](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/rest/create.go#L74)、[Storage.Create](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/dryrun.go#L36)、[AfterCreate](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/store.go#L153)以及[Decorator](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/registry/generic/registry/store.go#L148)等主要方法。对应于`POST`操作，则最主要的方法为[Storage.Create](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go#L144)。由于目前使用基本都是etcd3，所以实现的方法如下:
```go
// Create implements storage.Interface.Create.
func (s *store) Create(ctx context.Context, key string, obj, out runtime.Object, ttl uint64) error {
	if version, err := s.versioner.ObjectResourceVersion(obj); err == nil && version != 0 {
		return errors.New("resourceVersion should not be set on objects to be created")
	}
	if err := s.versioner.PrepareObjectForStorage(obj); err != nil {
		return fmt.Errorf("PrepareObjectForStorage failed: %v", err)
	}
	data, err := runtime.Encode(s.codec, obj)
	if err != nil {
		return err
	}
	key = path.Join(s.pathPrefix, key)

	opts, err := s.ttlOpts(ctx, int64(ttl))
	if err != nil {
		return err
	}

	newData, err := s.transformer.TransformToStorage(data, authenticatedDataString(key))
	if err != nil {
		return storage.NewInternalError(err.Error())
	}

	startTime := time.Now()
	txnResp, err := s.client.KV.Txn(ctx).If(
		notFound(key),
	).Then(
		clientv3.OpPut(key, string(newData), opts...),
	).Commit()
	metrics.RecordEtcdRequestLatency("create", getTypeName(obj), startTime)
	if err != nil {
		return err
	}
	if !txnResp.Succeeded {
		return storage.NewKeyExistsError(key, 0)
	}

	if out != nil {
		putResp := txnResp.Responses[0].GetResponsePut()
		return decode(s.codec, s.versioner, data, out, putResp.Header.Revision)
	}
	return nil
}
```
主要操作为：
1、调用[Encode](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apimachinery/pkg/runtime/codec.go#L47)方法序列化；
2、调用`path.Join`解析Key；
3、调用[TransformToStorage](https://github.com/kubernetes/kubernetes/blob/v1.18.4/staging/src/k8s.io/apiserver/pkg/storage/value/transformer.go#L48)将数据类型进行转换；
4、调用客户端方法进行etcd的写入操作。
至此，完成handler处理与对应的etcd数据库操作的绑定，即完成整个路由后端的操作步骤。

参考：
- https://github.com/kubernetes/kubernetes
- https://juejin.im/post/5c934e5a5188252d7c216981