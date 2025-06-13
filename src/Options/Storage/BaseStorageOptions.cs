// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System.Text.Json.Serialization;
using AzureMcp.Models.Option;

namespace AzureMcp.Options.Storage;

public class BaseStorageOptions : SubscriptionOptions
{
    [JsonPropertyName(OptionDefinitions.Storage.AccountName)]
    public string? Account { get; set; }
}
