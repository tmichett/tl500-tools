#!/bin/bash

#
# Lecture https://rht-labs.com/tech-exercise/#
#

# Help function
help() {
  echo -e "Usage: $0 -u=<USERNAME> -p=<PASSWORD> -t=<TEAM_NAME>"
  echo -e "Example: $0 -u=lab01 -p=lab01 -t=01team"
  exit 1
}

# Parse and check input
for i in "$@"; do
  case $i in
    -u=*)
      USERNAME="${i#*=}"
      shift
      ;;
    -p=*)
      PASSWORD="${i#*=}"
      shift
      ;;
    -t=*)
      TEAM_NAME="${i#*=}"
      shift
      ;;
    *)
      help
      ;;
  esac
done

# Check vars
if [ -z ${USERNAME} ] || [ -z ${PASSWORD} ] || [ -z ${TEAM_NAME} ]
then
  help
fi

#
# Configuration
#
CLUSTER_DOMAIN=apps.ocp4.example.com
GIT_SERVER=gitlab-ce.apps.ocp4.example.com
OCP_CONSOLE=https://console-openshift-console.apps.ocp4.example.com

#
# Patches
#
ARGO_PATCH="--version 0.4.9"
KEYCLOACK_PATCH="labs1.0.1"



#
# Login to OCP4 and open project
#
echo "Loging to OCP4"
oc login --server=https://api.${CLUSTER_DOMAIN##apps.}:6443 -u ${USERNAME} -p ${PASSWORD}
oc project ${TEAM_NAME}-ci-cd 



echo
echo "#################################################"
echo "### Attack of the Pipelines -> Sealed Secrets ###"
echo "#################################################"
echo
oc login --server=https://api.${CLUSTER_DOMAIN##apps.}:6443 -u ${USERNAME} -p ${PASSWORD} >/dev/null 2>&1

cd /projects/tech-exercise
git remote set-url origin https://${GIT_SERVER}/${TEAM_NAME}/tech-exercise.git
git pull

echo "GITLAB_USER: ${GITLAB_USER}"
echo "GITLAB_PAT: ${GITLAB_PAT}"

cat << EOF > /tmp/git-auth.yaml
kind: Secret
apiVersion: v1
data:
  username: "$(echo -n ${GITLAB_USER} | base64 -w0)"
  password: "$(echo -n ${GITLAB_PAT} | base64 -w0)"
type: kubernetes.io/basic-auth
metadata:
  annotations:
    tekton.dev/git-0: https://${GIT_SERVER}
    sealedsecrets.bitnami.com/managed: "true"
  labels:
    credential.sync.jenkins.openshift.io: "true"
  name: git-auth
EOF

oc login --server=https://api.${CLUSTER_DOMAIN##apps.}:6443 -u ${USERNAME} -p ${PASSWORD}

kubeseal < /tmp/git-auth.yaml > /tmp/sealed-git-auth.yaml \
    -n ${TEAM_NAME}-ci-cd \
    --controller-namespace tl500-shared \
    --controller-name sealed-secrets \
    -o yaml

cat /tmp/sealed-git-auth.yaml 
cat /tmp/sealed-git-auth.yaml | grep -E 'username|password'

if [[ $(yq e '.applications[] | select(.name=="sealed-secrets") | length' /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml) < 1 ]]; then
    yq e '.applications += {"name": "sealed-secrets","enabled": true,"source": "https://redhat-cop.github.io/helm-charts","chart_name": "helper-sealed-secrets","source_ref": "1.0.3","values": {"secrets": [{"name": "git-auth","type": "kubernetes.io/basic-auth","annotations": {"tekton.dev/git-0": "https://GIT_SERVER","sealedsecrets.bitnami.com/managed": "true"},"labels": {"credential.sync.jenkins.openshift.io": "true"},"data": {"username": "SEALED_SECRET_USERNAME","password": "SEALED_SECRET_PASSWORD"}}]}}' -i /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml
    SEALED_SECRET_USERNAME=$(yq e '.spec.encryptedData.username' /tmp/sealed-git-auth.yaml)
    SEALED_SECRET_PASSWORD=$(yq e '.spec.encryptedData.password' /tmp/sealed-git-auth.yaml)
    sed -i "s|GIT_SERVER|$GIT_SERVER|" /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml
    sed -i "s|SEALED_SECRET_USERNAME|$SEALED_SECRET_USERNAME|" /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml
    sed -i "s|SEALED_SECRET_PASSWORD|$SEALED_SECRET_PASSWORD|" /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml
fi

echo "See # Sealed Secret section"
cat  /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml

cd /projects/tech-exercise
git add ubiquitous-journey/values-tooling.yaml
git commit -m "Sealed secret of Git user creds is added"
git push

echo "==> Log to ${ARGO_URL} and verify SealedSecret chart. Drill into the SealedSecret and see the git-auth secret has synced."
read -p "Press [Enter] when done to continue..."

JENKINS_URL=$(echo https://$(oc get route jenkins --template='{{ .spec.host }}' -n ${TEAM_NAME}-ci-cd))
echo export JENKINS_URL="${JENKINS_URL}" | tee -a ~/.bashrc -a ~/.zshrc
echo "==> Log to ${JENKINS_URL} Verify Jenkins synced Jenkins -> Manage Jenkins -> Manage Credentials to view ${TEAM_NAME}-ci-cd-git-auth"
read -p "Press [Enter] when done to continue..."

echo
echo "##############################################################"
echo "### Attack of the Pipelines -> Application of Applications ###"
echo "##############################################################"
echo

echo "Deploying Pet Battle - Keycloak"

yq e '(.applications[] | (select(.name=="test-app-of-pb").enabled)) |=true' -i /projects/tech-exercise/values.yaml
yq e '(.applications[] | (select(.name=="staging-app-of-pb").enabled)) |=true' -i /projects/tech-exercise/values.yaml

if [[ $(yq e '.applications[] | select(.name=="keycloak") | length' /projects/tech-exercise/pet-battle/test/values.yaml) < 1 ]]; then
    yq e '.applications.keycloak = {"name": "keycloak","enabled": true,"source": "https://github.com/petbattle/pet-battle-infra","source_ref": "BRANCH_ID","source_path": "keycloak","values": {"app_domain": "CLUSTER_DOMAIN"}}' -i /projects/tech-exercise/pet-battle/test/values.yaml
    sed -i "s|CLUSTER_DOMAIN|${CLUSTER_DOMAIN}|" /projects/tech-exercise/pet-battle/test/values.yaml
    sed -i "s|BRANCH_ID|${KEYCLOACK_PATCH}|" /projects/tech-exercise/pet-battle/test/values.yaml
fi

echo "See keycloak object"
cat /projects/tech-exercise/pet-battle/test/values.yaml
sleep 180

cd /projects/tech-exercise
git add .
git commit -m  "ADD - app-of-apps and keycloak to test"
git push 

cd /projects/tech-exercise
helm upgrade --install uj --namespace ${TEAM_NAME}-ci-cd .

echo "==> Log to ${ARGO_URL} and verify staging-app-of-pb and test-app-of-pb."
read -p "Press [Enter] when done to continue..."

echo "Deploying Pet Battle Test"

if [[ $(yq e '.applications[] | select(.name=="pet-battle-api") | length' /projects/tech-exercise/pet-battle/test/values.yaml) < 1 ]]; then
    yq e '.applications.pet-battle-api = {"name": "pet-battle-api","enabled": true,"source": "https://petbattle.github.io/helm-charts","chart_name": "pet-battle-api","source_ref": "1.2.1","values": {"image_name": "pet-battle-api","image_version": "latest", "hpa": {"enabled": false}}}' -i /projects/tech-exercise/pet-battle/test/values.yaml
fi
if [[ $(yq e '.applications[] | select(.name=="pet-battle") | length' /projects/tech-exercise/pet-battle/test/values.yaml) < 1 ]]; then
    yq e '.applications.pet-battle = {"name": "pet-battle","enabled": true,"source": "https://petbattle.github.io/helm-charts","chart_name": "pet-battle","source_ref": "1.0.6","values": {"image_version": "latest"}}' -i /projects/tech-exercise/pet-battle/test/values.yaml
fi
sed -i '/^$/d' /projects/tech-exercise/pet-battle/test/values.yaml
sed -i '/^# Keycloak/d' /projects/tech-exercise/pet-battle/test/values.yaml
sed -i '/^# Pet Battle Apps/d' /projects/tech-exercise/pet-battle/test/values.yaml

export JSON="'"'{
        "catsUrl": "https://pet-battle-api-'${TEAM_NAME}'-test.'${CLUSTER_DOMAIN}'",
        "tournamentsUrl": "https://pet-battle-tournament-'${TEAM_NAME}'-test.'${CLUSTER_DOMAIN}'",
        "matomoUrl": "https://matomo-'${TEAM_NAME}'-ci-cd.'${CLUSTER_DOMAIN}'/",
        "keycloak": {
          "url": "https://keycloak-'${TEAM_NAME}'-test.'${CLUSTER_DOMAIN}'/auth/",
          "realm": "pbrealm",
          "clientId": "pbclient",
          "redirectUri": "http://localhost:4200/tournament",
          "enableLogging": true
        }
      }'"'"
yq e '.applications.pet-battle.values.config_map = env(JSON) | .applications.pet-battle.values.config_map style="single"' -i /projects/tech-exercise/pet-battle/test/values.yaml

echo "pet-battle test definition"
cat /projects/tech-exercise/pet-battle/test/values.yaml

echo "Deploying Pet Battle Stage"
cp -f /projects/tech-exercise/pet-battle/test/values.yaml /projects/tech-exercise/pet-battle/stage/values.yaml
sed -i "s|${TEAM_NAME}-test|${TEAM_NAME}-stage|" /projects/tech-exercise/pet-battle/stage/values.yaml
sed -i 's|release: "test"|release: "stage"|' /projects/tech-exercise/pet-battle/stage/values.yaml

echo "pet-battle stage definition"
cat /projects/tech-exercise/pet-battle/stage/values.yaml

cd /projects/tech-exercise
git add .
git commit -m  "ADD - pet battle apps"
git push

echo "==> Log to ${ARGO_URL} and verify Pet Battle apps for test and stage. Drill into one eg test-app-of-pb and see each of the three components of PetBattle"
read -p "Press [Enter] when done to continue..."

echo "==> Log to ${OCP_CONSOLE} Developer View -> Topology and select your ${TEAM_NAME}-test|stage ns -> Route )"
read -p "Press [Enter] when done to continue..."

echo
echo "#################################################"
echo "### Attack of the Pipelines -> The Pipelines  ###"
echo "#################################################"
echo

cd /projects/tech-exercise
git remote set-url origin https://${GIT_SERVER}/${TEAM_NAME}/tech-exercise.git
git pull

echo
echo "###########################################################"
echo "### Attack of the Pipelines -> The Pipelines - Jenkins  ###"
echo "###########################################################"
echo

echo "==> Log to https://${GIT_SERVER} and perform the manual steps 1). Create a Project in GitLab under ${TEAM_NAME} group called pet-battle. Make the project as public."
read -p "Press [Enter] when done to continue..."

cd /projects
git clone https://github.com/rht-labs/pet-battle.git && cd pet-battle
git remote set-url origin https://${GIT_SERVER}/${TEAM_NAME}/pet-battle.git
git branch -M main
git push -u origin main

PET_JEN_TOKEN=$(echo "https://$(oc get route jenkins --template='{{ .spec.host }}' -n ${TEAM_NAME}-ci-cd)/multibranch-webhook-trigger/invoke?token=pet-battle")

echo "==> Log to https://${GIT_SERVER} Add Pet Battle jenkins token ${PET_JEN_TOKEN} on pet-battle > Settings > Integrations."
read -p "Press [Enter] when done to continue..."

yq e '(.applications[] | (select(.name=="jenkins").values.deployment.env_vars[] | select(.name=="GITLAB_HOST")).value)|=env(GIT_SERVER)' -i /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml
yq e '(.applications[] | (select(.name=="jenkins").values.deployment.env_vars[] | select(.name=="GITLAB_GROUP_NAME")).value)|=env(TEAM_NAME)' -i /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml
yq e '.applications.pet-battle.source |="http://nexus:8081/repository/helm-charts"' -i /projects/tech-exercise/pet-battle/test/values.yaml

cd /projects/tech-exercise
git add .
git commit -m  "ADD - jenkins pipelines config"
git push
sleep 90

echo "==> Log to ${JENKINS_URL} See the seed job has scaffolded out a pipeline for the frontend in the Jenkins UI. It’s done this by looking in the pet-battle repo where it found the Jenkinsfile (our pipeline definition). However it will fail on the first execution. This is expected as we’re going write some stuff to fix it! - If after Jenkins restarts you do not see the job run, feel free to manually trigger it to get it going"
read -p "Press [Enter] when done to continue..."

#PROD
wget -O /projects/pet-battle/Jenkinsfile https://raw.githubusercontent.com/rht-labs/tech-exercise/main/tests/doc-regression-test-files/3a-jenkins-Jenkinsfile.groovy

cd /projects/pet-battle
git add Jenkinsfile
git commit -m "Jenkinsfile updated with build stage"
git push

echo "==> Log to ${JENKINS_URL} See the  pet-battle pipeline is running successfully. Use the Blue Ocean view,"
read -p "Press [Enter] when done to continue..."

echo
echo "##########################################################"
echo "### Attack of the Pipelines -> The Pipelines - Tekton  ###"
echo "##########################################################"
echo

echo "==> Log to https://${GIT_SERVER} and perform the manual steps 1). Create a Project in GitLab under ${TEAM_NAME} group called pet-battle-api. Make the project as internal."
read -p "Press [Enter] when done to continue..."

### TODO: This must be documented on the lectures
cd /projects/tech-exercise
git remote set-url origin https://${GIT_SERVER}/${TEAM_NAME}/tech-exercise.git
git pull
###

cd /projects
git clone https://github.com/rht-labs/pet-battle-api.git && cd pet-battle-api
git remote set-url origin https://${GIT_SERVER}/${TEAM_NAME}/pet-battle-api.git
git branch -M main
git push -u origin main

if [[ $(yq e '.applications[] | select(.name=="tekton-pipeline") | length' /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml) < 1 ]]; then
    yq e '.applications += {"name": "tekton-pipeline","enabled": true,"source": "https://GIT_SERVER/TEAM_NAME/tech-exercise.git","source_ref": "main","source_path": "tekton","values": {"team": "TEAM_NAME","cluster_domain": "CLUSTER_DOMAIN","git_server": "GIT_SERVER"}}' -i /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml
    sed -i "s|GIT_SERVER|$GIT_SERVER|" /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml
    sed -i "s|TEAM_NAME|$TEAM_NAME|" /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml    
    sed -i "s|CLUSTER_DOMAIN|$CLUSTER_DOMAIN|" /projects/tech-exercise/ubiquitous-journey/values-tooling.yaml    
fi

yq e '.applications.pet-battle-api.source |="http://nexus:8081/repository/helm-charts"' -i /projects/tech-exercise/pet-battle/test/values.yaml

cd /projects/tech-exercise
git add .
git commit -m  "ADD - tekton pipelines config"
git push

sleep 60
echo "==> Log to ${ARGO_URL} and verify ubiquitous-jorney app has a tekton-pipeline resource"
read -p "Press [Enter] when done to continue..." 

PET_API_TOKEN=$(echo https://$(oc -n ${TEAM_NAME}-ci-cd get route webhook --template='{{ .spec.host }}'))

echo "==> Log to https://${GIT_SERVER} Add Pet Battle API token ${PET_API_TOKEN} on pet-battle-api > Settings > Integrations. Test the hook with Project Hooks -> Test -> Push events"
read -p "Press [Enter] when done to continue..."

cd /projects/pet-battle-api
mvn -ntp versions:set -DnewVersion=1.3.1
sleep 100

cd /projects/pet-battle-api
git add .
git commit -m  "UPDATED - pet-battle-version to 1.3.1"
git push 

sleep 60
echo "==> Log to ${OCP_CONSOLE} Observe Pipeline running -> Pipelines -> Pipelines in your ${TEAM_NAME}-ci-cd project. Also, use the tkn command line to observe PipelineRun logs as well: 'tkn -n ${TEAM_NAME}-ci-cd pr logs -Lf'"
read -p "Press [Enter] when done to continue..."

