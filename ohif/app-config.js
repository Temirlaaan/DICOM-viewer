/**
 * =============================================================================
 * OHIF Viewer Configuration
 * =============================================================================
 * Configuration for OHIF v3.9.0 with:
 * - DICOMweb connection to Orthanc
 * - Keycloak OIDC authentication
 * - MPR and 3D visualization modes
 * =============================================================================
 */

window.config = {
  // ============================================================================
  // General Settings
  // ============================================================================
  routerBasename: '/',
  showStudyList: true,
  showWarningMessageForCrossOrigin: true,
  showCPUFallbackMessage: true,
  showLoadingIndicator: true,
  strictZSpacingForVolumeReconstruction: true,

  // Use web workers for performance
  useSharedArrayBuffer: 'AUTO',

  // ============================================================================
  // Investigation / Viewer Mode
  // ============================================================================
  investigationalUseDialog: {
    option: 'never',  // 'never', 'always', 'configure'
  },

  // ============================================================================
  // Data Sources - DICOMweb connection to Orthanc
  // ============================================================================
  dataSources: [
    {
      namespace: '@ohif/extension-default.dataSourcesModule.dicomweb',
      sourceName: 'orthanc',
      configuration: {
        friendlyName: 'Orthanc DICOMweb',
        name: 'orthanc',

        // DICOMweb endpoints (proxied through nginx)
        wadoUriRoot: '/wado',
        qidoRoot: '/dicom-web',
        wadoRoot: '/dicom-web',

        // Capabilities
        qidoSupportsIncludeField: true,
        supportsReject: false,
        supportsStow: false,           // Read-only for viewer
        imageRendering: 'wadors',
        thumbnailRendering: 'wadors',
        enableStudyLazyLoad: true,
        supportsFuzzyMatching: true,

        // Bulk data
        singlepart: 'bulkdata,video',
        bulkDataURI: {
          enabled: true,
          relativeResolution: 'studies',
        },

        // WADO-RS specific
        omitQuotationForMultipartRequest: true,

        // Static WADO settings
        staticWado: false,
      },
    },
  ],

  // Default data source
  defaultDataSourceName: 'orthanc',

  // ============================================================================
  // OIDC Authentication - Keycloak
  // ============================================================================
  oidc: [
    {
      // Keycloak realm URL
      authority: 'https://imaging.denscan.kz/auth/realms/dicom',

      // Client configuration
      client_id: 'ohif-viewer',
      redirect_uri: '/callback',
      post_logout_redirect_uri: '/',

      // Response type for PKCE flow
      response_type: 'code',

      // Scopes
      scope: 'openid profile email',

      // Silent refresh for token renewal
      automaticSilentRenew: true,
      silent_redirect_uri: '/silent-refresh.html',
      revokeTokensOnSignout: true,

      // Popup settings
      popupWindowFeatures: 'location=no,toolbar=no,width=800,height=600,left=200,top=200',

      // Extra settings
      filterProtocolClaims: true,
      loadUserInfo: true,
      accessTokenExpiringNotificationTimeInSeconds: 60,
    },
  ],

  // ============================================================================
  // Hanging Protocols
  // ============================================================================
  hangingProtocols: [
    // Default hanging protocols are included from extensions
  ],

  // ============================================================================
  // Extensions
  // ============================================================================
  extensions: [
    // Core extensions
    '@ohif/extension-default',
    '@ohif/extension-cornerstone',
    '@ohif/extension-cornerstone-dicom-sr',
    '@ohif/extension-cornerstone-dicom-seg',
    '@ohif/extension-cornerstone-dicom-rt',
    '@ohif/extension-measurement-tracking',
    '@ohif/extension-dicom-pdf',
    '@ohif/extension-dicom-video',
  ],

  // ============================================================================
  // Modes
  // ============================================================================
  modes: [
    // Basic viewer mode
    '@ohif/mode-basic-viewer',

    // Measurement tracking mode
    '@ohif/mode-tracking',

    // MPR mode for multiplanar reconstruction
    '@ohif/mode-mpr',
  ],

  // ============================================================================
  // Customization
  // ============================================================================
  customizationService: {
    // Global customizations
    global: [
      // You can add custom toolbar buttons, panels, etc.
    ],

    // Mode-specific customizations
    modeCustomizations: {},
  },

  // ============================================================================
  // Hotkeys
  // ============================================================================
  hotkeys: [
    // Default OHIF hotkeys
    { commandName: 'incrementActiveViewport', label: 'Next Viewport', keys: ['right'] },
    { commandName: 'decrementActiveViewport', label: 'Previous Viewport', keys: ['left'] },
    { commandName: 'rotateViewportCW', label: 'Rotate CW', keys: ['r'] },
    { commandName: 'rotateViewportCCW', label: 'Rotate CCW', keys: ['l'] },
    { commandName: 'flipViewportVertical', label: 'Flip Vertical', keys: ['v'] },
    { commandName: 'flipViewportHorizontal', label: 'Flip Horizontal', keys: ['h'] },
    { commandName: 'scaleUpViewport', label: 'Zoom In', keys: ['+'] },
    { commandName: 'scaleDownViewport', label: 'Zoom Out', keys: ['-'] },
    { commandName: 'fitViewportToWindow', label: 'Zoom to Fit', keys: ['='] },
    { commandName: 'resetViewport', label: 'Reset Viewport', keys: ['space'] },
    { commandName: 'nextImage', label: 'Next Image', keys: ['down'] },
    { commandName: 'previousImage', label: 'Previous Image', keys: ['up'] },
    { commandName: 'firstImage', label: 'First Image', keys: ['home'] },
    { commandName: 'lastImage', label: 'Last Image', keys: ['end'] },
    { commandName: 'setToolActive', commandOptions: { toolName: 'Zoom' }, label: 'Zoom', keys: ['z'] },
    { commandName: 'setToolActive', commandOptions: { toolName: 'WindowLevel' }, label: 'W/L', keys: ['w'] },
    { commandName: 'setToolActive', commandOptions: { toolName: 'Pan' }, label: 'Pan', keys: ['p'] },
    { commandName: 'setToolActive', commandOptions: { toolName: 'Length' }, label: 'Length', keys: ['m'] },
    { commandName: 'invertViewport', label: 'Invert', keys: ['i'] },
    { commandName: 'toggleCine', label: 'Cine Play', keys: ['c'] },
  ],

  // ============================================================================
  // WhiteLabeling (Optional - customize appearance)
  // ============================================================================
  whiteLabeling: {
    // Custom logo
    createLogoComponentFn: function(React) {
      return React.createElement(
        'div',
        {
          style: {
            display: 'flex',
            alignItems: 'center',
            padding: '0 12px',
          },
        },
        React.createElement(
          'span',
          {
            style: {
              color: 'white',
              fontSize: '16px',
              fontWeight: 'bold',
            },
          },
          'DenScan Imaging'
        )
      );
    },
  },

  // ============================================================================
  // Study List Filters
  // ============================================================================
  studyListFunctionsEnabled: true,
  maxNumberOfWebWorkers: 4,

  // Default study list filter
  defaultStudyListSort: {
    field: 'studyDate',
    direction: 'descending',
  },

  // ============================================================================
  // Viewport Settings
  // ============================================================================
  maxNumRequests: {
    interaction: 100,
    thumbnail: 75,
    prefetch: 25,
  },

  // ============================================================================
  // Segmentation Settings
  // ============================================================================
  cornerstoneExtensionConfig: {
    tools: {
      // Tool configurations
    },
  },
};

// ============================================================================
// Development Mode Overrides
// ============================================================================
if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') {
  // Override for local development
  window.config.oidc[0].authority = window.location.protocol + '//' + window.location.host + '/auth/realms/dicom';
  window.config.oidc[0].redirect_uri = window.location.origin + '/callback';
  window.config.oidc[0].post_logout_redirect_uri = window.location.origin + '/';
  window.config.oidc[0].silent_redirect_uri = window.location.origin + '/silent-refresh.html';

  // For development without auth, you can disable OIDC:
  // window.config.oidc = [];
}
