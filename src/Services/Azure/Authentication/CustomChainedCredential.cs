// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System.Text;
using Azure.Core;
using Azure.Identity;
using Azure.Identity.Broker;
using AzureMcp.Helpers;

namespace AzureMcp.Services.Azure.Authentication;

/// <summary>
/// A custom token credential that chains the Identity Broker-enabled InteractiveBrowserCredential 
/// with DefaultAzureCredential to provide a seamless authentication experience.
/// </summary>
/// <remarks>
/// This credential attempts authentication in the following order:
/// 1. Interactive browser authentication with Identity Broker (supporting Windows Hello, biometrics, etc.)
/// 2. DefaultAzureCredential chain (environment variables, managed identity, CLI, etc.)
/// </remarks>
public class CustomChainedCredential(string? tenantId = null) : TokenCredential
{
    private ChainedTokenCredential? _chainedCredential;

    public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
    {
        _chainedCredential ??= CreateChainedCredential(tenantId);
        return _chainedCredential.GetToken(requestContext, cancellationToken);
    }

    public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
    {
        _chainedCredential ??= CreateChainedCredential(tenantId);
        return _chainedCredential.GetTokenAsync(requestContext, cancellationToken);
    }

    private const string AuthenticationRecordEnvVarName = "AZURE_MCP_AUTHENTICATION_RECORD";
    private const string BrowserAuthenticationTimeoutEnvVarName = "AZURE_MCP_BROWSER_AUTH_TIMEOUT_SECONDS";
    private const string OnlyUseBrokerCredentialEnvVarName = "AZURE_MCP_ONLY_USE_BROKER_CREDENTIAL";
    private const string ClientIdEnvVarName = "AZURE_MCP_CLIENT_ID";
    private const string IncludeProductionCredentialEnvVarName = "AZURE_MCP_INCLUDE_PRODUCTION_CREDENTIALS";

    private static bool ShouldUseOnlyBrokerCredential()
    {
        return EnvironmentHelpers.GetEnvironmentVariableAsBool(OnlyUseBrokerCredentialEnvVarName);
    }

    private static ChainedTokenCredential CreateChainedCredential(string? tenantId)
    {
        string? authRecordJson = Environment.GetEnvironmentVariable(AuthenticationRecordEnvVarName);
        AuthenticationRecord? authRecord = null;
        if (!string.IsNullOrEmpty(authRecordJson))
        {
            byte[] bytes = Encoding.UTF8.GetBytes(authRecordJson);
            using MemoryStream authRecordStream = new MemoryStream(bytes);
            authRecord = AuthenticationRecord.Deserialize(authRecordStream);
        }

        if (ShouldUseOnlyBrokerCredential())
        {
            return new(CreateBrowserCredential(tenantId, authRecord));
        }
        else
        {
            return new(CreateDefaultCredential(tenantId), CreateBrowserCredential(tenantId, authRecord));
        }
    }

    private static string TokenCacheName = "azure-mcp-msal.cache";

    private static TokenCredential CreateBrowserCredential(string? tenantId, AuthenticationRecord? authRecord)
    {
        string? clientId = Environment.GetEnvironmentVariable(ClientIdEnvVarName);

        IntPtr handle = WindowHandleProvider.GetWindowHandle();

        InteractiveBrowserCredentialBrokerOptions brokerOptions = new(handle)
        {
            UseDefaultBrokerAccount = !ShouldUseOnlyBrokerCredential() && authRecord is null,
            TenantId = string.IsNullOrEmpty(tenantId) ? null : tenantId,
            AuthenticationRecord = authRecord,
            TokenCachePersistenceOptions = new TokenCachePersistenceOptions()
            {
                Name = TokenCacheName,
            }
        };

        if (clientId is not null)
        {
            brokerOptions.ClientId = clientId;
        }

        var browserCredential = new InteractiveBrowserCredential(brokerOptions);

        // Check for timeout value in the environment variable
        string? timeoutValue = Environment.GetEnvironmentVariable(BrowserAuthenticationTimeoutEnvVarName);
        int timeoutSeconds = 300; // Default to 300 seconds (5 minutes)
        if (!string.IsNullOrEmpty(timeoutValue) && int.TryParse(timeoutValue, out int parsedTimeout) && parsedTimeout > 0)
        {
            timeoutSeconds = parsedTimeout;
        }
        return new TimeoutTokenCredential(browserCredential, TimeSpan.FromSeconds(timeoutSeconds));
    }

    private static DefaultAzureCredential CreateDefaultCredential(string? tenantId)
    {
        var includeProdCreds = EnvironmentHelpers.GetEnvironmentVariableAsBool(IncludeProductionCredentialEnvVarName);

        var defaultCredentialOptions = new DefaultAzureCredentialOptions
        {
            ExcludeWorkloadIdentityCredential = !includeProdCreds,
            ExcludeManagedIdentityCredential = !includeProdCreds
        };

        if (!string.IsNullOrEmpty(tenantId))
        {
            defaultCredentialOptions.TenantId = tenantId;
        }

        return new DefaultAzureCredential(defaultCredentialOptions);
    }
}
