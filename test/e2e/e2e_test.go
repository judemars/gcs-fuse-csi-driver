/*
Copyright 2018 The Kubernetes Authors.
Copyright 2022 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/googlecloudplatform/gcs-fuse-csi-driver/pkg/cloud_provider/clientset"
	"github.com/googlecloudplatform/gcs-fuse-csi-driver/pkg/cloud_provider/metadata"
	"github.com/googlecloudplatform/gcs-fuse-csi-driver/test/e2e/testsuites"
	"github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/klog/v2"
	"k8s.io/kubernetes/test/e2e/framework"
	storageframework "k8s.io/kubernetes/test/e2e/storage/framework"
)

var (
	err error
	c   clientset.Interface
	m   metadata.Service
	bl  string
)

var _ = func() bool {
	testing.Init()
	if os.Getenv(clientcmd.RecommendedConfigPathEnvVar) == "" {
		kubeconfig := filepath.Join(os.Getenv("HOME"), ".kube", "config")
		os.Setenv(clientcmd.RecommendedConfigPathEnvVar, kubeconfig)
	}

	framework.RegisterCommonFlags(flag.CommandLine)
	framework.RegisterClusterFlags(flag.CommandLine)
	flag.Parse()
	framework.AfterReadingAllFlags(&framework.TestContext)

	c, err = clientset.New(framework.TestContext.KubeConfig)
	if err != nil {
		klog.Fatalf("Failed to configure k8s client: %v", err)
	}

	kubeConfig, err := clientcmd.LoadFromFile(framework.TestContext.KubeConfig)
	if err != nil {
		klog.Fatalf("Failed to load kube config: %v", err)
	}

	currentCluster := kubeConfig.CurrentContext
	framework.Logf("Running test on cluster %s", currentCluster)
	l := strings.Split(currentCluster, "_")
	if len(l) < 4 || l[0] != "gke" {
		klog.Fatalf("Got invalid cluster name %v, please make sure the cluster is created on GKE", currentCluster)
	}
	m, err = metadata.NewFakeService(l[1], l[2], l[3], os.Getenv("E2E_TEST_API_ENV"))
	if err != nil {
		klog.Fatal(err)
	}

	bl = os.Getenv("E2E_TEST_BUCKET_LOCATION")

	return true
}()

func TestE2E(t *testing.T) {
	t.Parallel()
	gomega.RegisterFailHandler(framework.Fail)
	if framework.TestContext.ReportDir != "" {
		if err := os.MkdirAll(framework.TestContext.ReportDir, 0o755); err != nil {
			klog.Errorf("Failed creating report directory: %v", err)
		}
	}

	suiteConfig, reporterConfig := framework.CreateGinkgoConfig()
	klog.Infof("Starting e2e run %q on Ginkgo node %d", framework.RunID, suiteConfig.ParallelProcess)
	ginkgo.RunSpecs(t, "Cloud Storage FUSE CSI E2E Suite", suiteConfig, reporterConfig)
}

var _ = ginkgo.Describe("Cloud Storage FUSE CSI Driver E2E", func() {
	GCSFuseCSITestSuites := []func() storageframework.TestSuite{
		testsuites.InitGcsFuseCSIVolumesTestSuite,
		testsuites.InitGcsFuseCSIFailedMountTestSuite,
		testsuites.InitGcsFuseCSIWorkloadsTestSuite,
		testsuites.InitGcsFuseCSIMultiVolumeTestSuite,
		testsuites.InitGcsFuseCSIGCSFuseIntegrationTestSuite,
		testsuites.InitGcsFuseCSIPerformanceTestSuite,
	}

	testDriver := InitGCSFuseCSITestDriver(c, m, bl)

	ginkgo.Context(storageframework.GetDriverNameWithFeatureTags(testDriver), func() {
		storageframework.DefineTestSuites(testDriver, GCSFuseCSITestSuites)
	})
})
