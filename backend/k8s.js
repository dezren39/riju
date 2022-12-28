import * as k8sClient from "@kubernetes/client-node";

const kubeconfig = new k8sClient.KubeConfig();
kubeconfig.loadFromDefault();

const k8s = kubeconfig.makeApiClient(k8sClient.CoreV1Api);

async function listUserSessions() {
  return (await k8s.listNamespacedPod("riju-user")).body.items.map((pod) => ({
    podName: pod.metadata.name,
    sessionID: pod.metadata.labels["riju.codes/user-session-id"],
  }));
}

async function createUserSession({ sessionID, langConfig, revisions }) {
  await k8s.createNamespacedPod("riju-user", {
    metadata: {
      name: `riju-user-session-${sessionID}`,
      labels: {
        "riju.codes/user-session-id": sessionID,
      },
    },
    spec: {
      volumes: [
        {
          name: "minio-config",
          secret: {
            secretName: "minio-user-login",
          },
        },
        {
          name: "riju-bin",
          emptyDir: {},
        },
      ],
      imagePullSecrets: [
        {
          name: "registry-user-login",
        },
      ],
      initContainers: [
        {
          name: "download",
          image: "minio/mc:RELEASE.2022-12-13T00-23-28Z",
          resources: {},
          args: [
            "sh",
            "-c",
            `mc cp riju/agent/${revisions.agent} /riju-bin/agent &&` +
              `mc cp riju/ptyify/${revisions.ptyify} /riju-bin/ptyify`,
          ],
          volumeMounts: [
            {
              name: "minio-config",
              mountPath: "/root/.mc",
              readOnly: true,
            },
            {
              name: "riju-bin",
              mountPath: "/riju-bin",
            },
          ],
        },
      ],
      containers: [
        {
          name: "session",
          image: `localhost:30999/riju-lang:${langConfig.id}-${revisions.langImage}`,
          resources: {
            limits: {
              cpu: "1000m",
              memory: "4Gi",
            },
          },
          startupProbe: {
            httpGet: {
              path: "/health",
              port: 869,
              scheme: "HTTP",
            },
            failureThreshold: 30,
            initialDelaySeconds: 0,
            periodSeconds: 1,
            successThreshold: 1,
            timeoutSeconds: 2,
          },
          readinessProbe: {
            httpGet: {
              path: "/health",
              port: 869,
              scheme: "HTTP",
            },
            failureThreshold: 1,
            initialDelaySeconds: 2,
            periodSeconds: 10,
            successThreshold: 1,
            timeoutSeconds: 2,
          },
          livenessProbe: {
            httpGet: {
              path: "/health",
              port: 869,
              scheme: "HTTP",
            },
            failureThreshold: 3,
            initialDelaySeconds: 2,
            periodSeconds: 10,
            successThreshold: 1,
            timeoutSeconds: 2,
          },
          volumeMounts: [
            {
              name: "riju-bin",
              mountPath: "/riju-bin",
              readOnly: true,
            },
          ],
        },
      ],
      restartPolicy: "Never",
    },
  });
}