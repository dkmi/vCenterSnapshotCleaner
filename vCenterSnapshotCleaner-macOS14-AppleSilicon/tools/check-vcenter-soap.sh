#!/usr/bin/env bash
set -euo pipefail

: "${VCENTER:?Set VCENTER, for example: VCENTER=vcenter.example.local}"
: "${VCENTER_USER:?Set VCENTER_USER, for example: VCENTER_USER=administrator@vsphere.local}"
: "${VCENTER_PASSWORD:?Set VCENTER_PASSWORD}"

API_VERSION="${VCENTER_API_VERSION:-6.5}"
BASE_URL="https://${VCENTER%/}/sdk"
COOKIE_JAR="$(mktemp)"
SERVICE_CONTENT_XML="$(mktemp)"
LOGIN_XML="$(mktemp)"
VIEW_XML="$(mktemp)"
PROPS_XML="$(mktemp)"

cleanup() {
  rm -f "$COOKIE_JAR" "$SERVICE_CONTENT_XML" "$LOGIN_XML" "$VIEW_XML" "$PROPS_XML"
}
trap cleanup EXIT

cat > "$SERVICE_CONTENT_XML" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">
  <soapenv:Body>
    <RetrieveServiceContent xmlns="urn:vim25">
      <_this type="ServiceInstance">ServiceInstance</_this>
    </RetrieveServiceContent>
  </soapenv:Body>
</soapenv:Envelope>
XML

echo "Checking RetrieveServiceContent on ${BASE_URL}"
curl -ksS \
  -H "Content-Type: text/xml; charset=utf-8" \
  -H "SOAPAction: \"urn:vim25/${API_VERSION}\"" \
  -c "$COOKIE_JAR" \
  --data-binary "@${SERVICE_CONTENT_XML}" \
  "$BASE_URL" | tee /tmp/vcenter-service-content.xml

SESSION_MANAGER="$(sed -n 's:.*<sessionManager[^>]*>\([^<]*\)</sessionManager>.*:\1:p' /tmp/vcenter-service-content.xml | head -1)"
PROPERTY_COLLECTOR="$(sed -n 's:.*<propertyCollector[^>]*>\([^<]*\)</propertyCollector>.*:\1:p' /tmp/vcenter-service-content.xml | head -1)"
ROOT_FOLDER="$(sed -n 's:.*<rootFolder[^>]*>\([^<]*\)</rootFolder>.*:\1:p' /tmp/vcenter-service-content.xml | head -1)"
VIEW_MANAGER="$(sed -n 's:.*<viewManager[^>]*>\([^<]*\)</viewManager>.*:\1:p' /tmp/vcenter-service-content.xml | head -1)"
if [[ -z "$SESSION_MANAGER" ]]; then
  echo
  echo "Could not find sessionManager in SOAP response. Check /tmp/vcenter-service-content.xml"
  exit 1
fi
if [[ -z "$PROPERTY_COLLECTOR" || -z "$ROOT_FOLDER" || -z "$VIEW_MANAGER" ]]; then
  echo
  echo "Could not find propertyCollector/rootFolder/viewManager in SOAP response."
  exit 1
fi

cat > "$LOGIN_XML" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">
  <soapenv:Body>
    <Login xmlns="urn:vim25">
      <_this type="SessionManager">${SESSION_MANAGER}</_this>
      <userName>${VCENTER_USER}</userName>
      <password>${VCENTER_PASSWORD}</password>
      <locale>en</locale>
    </Login>
  </soapenv:Body>
</soapenv:Envelope>
XML

echo
echo "Checking SOAP Login as ${VCENTER_USER}"
curl -ksS \
  -H "Content-Type: text/xml; charset=utf-8" \
  -H "SOAPAction: \"urn:vim25/${API_VERSION}\"" \
  -b "$COOKIE_JAR" \
  -c "$COOKIE_JAR" \
  --data-binary "@${LOGIN_XML}" \
  "$BASE_URL" | tee /tmp/vcenter-login.xml

cat > "$VIEW_XML" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">
  <soapenv:Body>
    <CreateContainerView xmlns="urn:vim25">
      <_this type="ViewManager">${VIEW_MANAGER}</_this>
      <container type="Folder">${ROOT_FOLDER}</container>
      <type>VirtualMachine</type>
      <recursive>true</recursive>
    </CreateContainerView>
  </soapenv:Body>
</soapenv:Envelope>
XML

echo
echo "Checking CreateContainerView for VirtualMachine"
curl -ksS \
  -H "Content-Type: text/xml; charset=utf-8" \
  -H "SOAPAction: \"urn:vim25/${API_VERSION}\"" \
  -b "$COOKIE_JAR" \
  -c "$COOKIE_JAR" \
  --data-binary "@${VIEW_XML}" \
  "$BASE_URL" | tee /tmp/vcenter-view.xml

CONTAINER_VIEW="$(sed -n 's:.*<returnval[^>]*>\([^<]*\)</returnval>.*:\1:p' /tmp/vcenter-view.xml | head -1)"
if [[ -z "$CONTAINER_VIEW" ]]; then
  echo
  echo "Could not find ContainerView return value. Check /tmp/vcenter-view.xml"
  exit 1
fi

cat > "$PROPS_XML" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">
  <soapenv:Body>
    <RetrievePropertiesEx xmlns="urn:vim25" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <_this type="PropertyCollector">${PROPERTY_COLLECTOR}</_this>
      <specSet>
        <propSet>
          <type>VirtualMachine</type>
          <pathSet>name</pathSet>
          <pathSet>runtime.powerState</pathSet>
          <pathSet>snapshot</pathSet>
          <pathSet>recentTask</pathSet>
        </propSet>
        <objectSet>
          <obj type="ContainerView">${CONTAINER_VIEW}</obj>
          <skip>true</skip>
          <selectSet xsi:type="TraversalSpec">
            <name>view</name>
            <type>ContainerView</type>
            <path>view</path>
            <skip>false</skip>
          </selectSet>
        </objectSet>
      </specSet>
      <options/>
    </RetrievePropertiesEx>
  </soapenv:Body>
</soapenv:Envelope>
XML

echo
echo "Checking RetrievePropertiesEx for VMs"
curl -ksS \
  -H "Content-Type: text/xml; charset=utf-8" \
  -H "SOAPAction: \"urn:vim25/${API_VERSION}\"" \
  -b "$COOKIE_JAR" \
  -c "$COOKIE_JAR" \
  --data-binary "@${PROPS_XML}" \
  "$BASE_URL" | tee /tmp/vcenter-vms.xml

echo
echo "Done. Inspect /tmp/vcenter-service-content.xml, /tmp/vcenter-login.xml, /tmp/vcenter-view.xml and /tmp/vcenter-vms.xml if needed."
