//////////////////////////////////////////////////////////////////////////////////////////////////
//
//  SSLSecurity.swift
//  Starscream
//
//  Created by Dalton Cherry on 5/16/15.
//  Copyright (c) 2014-2015 Dalton Cherry.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//
//////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation

public class SSLCert {
    var certData: Data?
    var key: SecKey?
    
    /**
    Designated init for certificates
    
    - parameter data: is the binary data of the certificate
    
    - returns: a representation security object to be used with
    */
    public init(data: Data) {
        self.certData = data
    }
    
    /**
    Designated init for public keys
    
    - parameter key: is the public key to be used
    
    - returns: a representation security object to be used with
    */
    public init(key: SecKey) {
        self.key = key
    }
}

public class SSLSecurity {
    public var validatedDN = true //should the domain name be validated?
    
    var isReady = false //is the key processing done?
    var certificates: [Data]? //the certificates
    var pubKeys: [SecKey]? //the public keys
    var usePublicKeys = false //use public keys or certificate validation?
    
    /**
    Use certs from main app bundle
    
    - parameter usePublicKeys: is to specific if the publicKeys or certificates should be used for SSL pinning validation
    
    - returns: a representation security object to be used with
    */
    public convenience init(usePublicKeys: Bool = false) {
        let paths = Bundle.main.pathsForResources(ofType: "cer", inDirectory: ".")
        
        let certs = paths.reduce([SSLCert]()) { (certs: [SSLCert], path: String) -> [SSLCert] in
            var certs = certs
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                certs.append(SSLCert(data: data))
            }
            return certs
        }
        
        self.init(certs: certs, usePublicKeys: usePublicKeys)
    }
    
    /**
    Designated init
    
    - parameter keys: is the certificates or public keys to use
    - parameter usePublicKeys: is to specific if the publicKeys or certificates should be used for SSL pinning validation
    
    - returns: a representation security object to be used with
    */
    public init(certs: [SSLCert], usePublicKeys: Bool) {
        self.usePublicKeys = usePublicKeys
        
        if self.usePublicKeys {
            DispatchQueue.global(attributes: DispatchQueue.GlobalAttributes.qosDefault).async {
                let pubKeys = certs.reduce([SecKey]()) { (pubKeys: [SecKey], cert: SSLCert) -> [SecKey] in
                    var pubKeys = pubKeys
                    if let data = cert.certData where cert.key == nil {
                        cert.key = self.extractPublicKey(data)
                    }
                    if let key = cert.key {
                        pubKeys.append(key)
                    }
                    return pubKeys
                }
                
                self.pubKeys = pubKeys
                self.isReady = true
            }
        } else {
            let certificates = certs.reduce([Data]()) { (certificates: [Data], cert: SSLCert) -> [Data] in
                var certificates = certificates
                if let data = cert.certData {
                    certificates.append(data)
                }
                return certificates
            }
            self.certificates = certificates
            self.isReady = true
        }
    }
    
    /**
    Valid the trust and domain name.
    
    - parameter trust: is the serverTrust to validate
    - parameter domain: is the CN domain to validate
    
    - returns: if the key was successfully validated
    */
    public func isValid(_ trust: SecTrust, domain: String?) -> Bool {
        
        var tries = 0
        while(!self.isReady) {
            usleep(1000)
            tries += 1
            if tries > 5 {
                return false //doesn't appear it is going to ever be ready...
            }
        }
        var policy: SecPolicy
        if self.validatedDN {
            policy = SecPolicyCreateSSL(true, domain)
        } else {
            policy = SecPolicyCreateBasicX509()
        }
        SecTrustSetPolicies(trust,policy)
        if self.usePublicKeys {
            if let keys = self.pubKeys {
                let serverPubKeys = publicKeyChainForTrust(trust)
                for serverKey in serverPubKeys as [AnyObject] {
                    for key in keys as [AnyObject] {
                        if serverKey.isEqual(key) {
                            return true
                        }
                    }
                }
            }
        } else if let certs = self.certificates {
            let serverCerts = certificateChainForTrust(trust)
            var collect = [SecCertificate]()
            for cert in certs {
                collect.append(SecCertificateCreateWithData(nil,cert)!)
            }
            SecTrustSetAnchorCertificates(trust,collect)
            var result = SecTrustResultType.invalid
            SecTrustEvaluate(trust,&result)
            let r = result
            if r == SecTrustResultType.unspecified || r == SecTrustResultType.proceed {
                var trustedCount = 0
                for serverCert in serverCerts {
                    for cert in certs {
                        if cert == serverCert {
                            trustedCount += 1
                            break
                        }
                    }
                }
                if trustedCount == serverCerts.count {
                    return true
                }
            }
        }
        return false
    }
    
    /**
    Get the public key from a certificate data
    
    - parameter data: is the certificate to pull the public key from
    
    - returns: a public key
    */
    func extractPublicKey(_ data: Data) -> SecKey? {
        guard let cert = SecCertificateCreateWithData(nil, data) else { return nil }
        
        return extractPublicKeyFromCert(cert, policy: SecPolicyCreateBasicX509())
    }
    
    /**
    Get the public key from a certificate
    
    - parameter data: is the certificate to pull the public key from
    
    - returns: a public key
    */
    func extractPublicKeyFromCert(_ cert: SecCertificate, policy: SecPolicy) -> SecKey? {
        var possibleTrust: SecTrust?
        SecTrustCreateWithCertificates(cert, policy, &possibleTrust)
        
        guard let trust = possibleTrust else { return nil }
        
        var result = SecTrustResultType.invalid
        SecTrustEvaluate(trust, &result)
        return SecTrustCopyPublicKey(trust)
    }
    
    /**
    Get the certificate chain for the trust
    
    - parameter trust: is the trust to lookup the certificate chain for
    
    - returns: the certificate chain for the trust
    */
    func certificateChainForTrust(_ trust: SecTrust) -> [Data] {
        let certificates = (0..<SecTrustGetCertificateCount(trust)).reduce([Data]()) { (certificates: [Data], index: Int) -> [Data] in
            var certificates = certificates
            let cert = SecTrustGetCertificateAtIndex(trust, index)
            certificates.append(SecCertificateCopyData(cert!) as Data)
            return certificates
        }
        
        return certificates
    }
    
    /**
    Get the public key chain for the trust
    
    - parameter trust: is the trust to lookup the certificate chain and extract the public keys
    
    - returns: the public keys from the certifcate chain for the trust
    */
    func publicKeyChainForTrust(_ trust: SecTrust) -> [SecKey] {
        let policy = SecPolicyCreateBasicX509()
        let keys = (0..<SecTrustGetCertificateCount(trust)).reduce([SecKey]()) { (keys: [SecKey], index: Int) -> [SecKey] in
            var keys = keys
            let cert = SecTrustGetCertificateAtIndex(trust, index)
            if let key = extractPublicKeyFromCert(cert!, policy: policy) {
                keys.append(key)
            }
            
            return keys
        }
        
        return keys
    }
    
    
}
