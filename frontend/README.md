docker build -t heschmat/flaskapp-fe:latest .


kubectl exec -n $NS -it frontend-6dc46569cb-hk2qt -- wget -qO- http://backend.flaskapp.svc.cluster.local:8000/api/topics